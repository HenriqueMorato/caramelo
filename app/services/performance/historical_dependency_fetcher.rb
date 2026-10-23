module Performance
  class HistoricalDependencyFetcher
    PRICE_PROVIDER = MarketData::YahooFinance::MARKET_CONFIGURATION.identifier
    RATE_PROVIDER = MarketData::YahooFinance::FX_CONFIGURATION.identifier
    MAX_RANGE_DAYS = 30.years.in_days.ceil
    REQUIREMENT_BATCH_SIZE = 8

    PriceRequirement = Data.define(:instrument, :dates) do
      def price? = true
    end
    RateRequirement = Data.define(:base_currency, :quote_currency, :dates) do
      def price? = false
    end
    MissingDependency = Data.define(:label, :dates)

    class Unavailable < StandardError
      include MarketData::DateRangeFormatting

      attr_reader :dependencies

      def initialize(dependencies)
        @dependencies = dependencies
        details = dependencies.map { |dependency| "#{dependency.label} missing for #{format_dates(dependency.dates)}" }
        super("Historical data remains unavailable: #{details.join('; ')}")
      end
    end

    def self.call(user:, reporting_currency:, from:, to:, instrument: nil, price_importer: DailyClosingPrice::Importer.default,
      rate_importer: HistoricalExchangeRate::Importer.default, progress: nil, refetch_full_range: false,
      enqueue_performance_rebuilds: true, throttle: nil, cache: Rails.cache, allow_long_range: false)
      new(user:, instrument:, reporting_currency:, price_importer:, rate_importer:, progress:,
        enqueue_performance_rebuilds:, throttle:, cache:)
        .call(from:, to:, refetch_full_range:, allow_long_range:)
    end

    def initialize(user:, reporting_currency:, instrument: nil, price_importer: DailyClosingPrice::Importer.default,
      rate_importer: HistoricalExchangeRate::Importer.default, progress: nil, enqueue_performance_rebuilds: true,
      throttle: nil, cache: Rails.cache)
      @user = user
      @instrument = instrument
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
      @price_importer = price_importer
      @rate_importer = rate_importer
      @progress = progress || ->(_message) { }
      @enqueue_performance_rebuilds = enqueue_performance_rebuilds
      @throttle = throttle
      @cache = cache
    end

    def call(from:, to:, refetch_full_range: false, allow_long_range: false)
      validate_range!(from:, to:, allow_long_range:)
      prepare_range(from:, to:)
      requirements = dependencies
      fetch_dependencies(requirements, refetch_full_range:)
      raise_if_dependencies_missing(requirements)
      enqueue_performance_rebuilds if fetched_dependencies? && @enqueue_performance_rebuilds

      requirements
    end

    private

    attr_reader :user, :instrument, :reporting_currency, :price_importer, :rate_importer, :progress, :from, :to,
      :throttle, :cache

    def prepare_range(from:, to:)
      @from = from
      @to = to
      @trades = nil
      @actions = nil
      @price_requirements = nil
      @fetched_dependencies = false
    end

    def dependencies
      prices = price_requirements
      prices + rate_requirements(prices)
    end

    def fetch_dependencies(requirements, refetch_full_range:)
      @fetched_dependencies = requirements.each_slice(REQUIREMENT_BATCH_SIZE).sum do |batch|
        batch.count { |requirement| fetch(requirement, refetch_full_range:) }
      end.positive?
    end

    def fetched_dependencies?
      @fetched_dependencies
    end

    def raise_if_dependencies_missing(requirements)
      missing = requirements.filter_map do |requirement|
        dates = missing_dates(requirement)
        MissingDependency.new(label: label_for(requirement), dates:) unless dates.empty?
      end
      raise Unavailable, missing if missing.any?
    end

    def validate_range!(from:, to:, allow_long_range:)
      valid_dates = from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current
      raise ArgumentError, "dependency range must use past dates in chronological order" unless valid_dates
      return if allow_long_range || (to - from).to_i <= MAX_RANGE_DAYS

      raise ArgumentError, "dependency range exceeds the maximum recovery span"
    end

    def price_requirements
      @price_requirements ||= instruments.filter_map do |target_instrument|
        dates = open_position_dates(target_instrument)
        next if dates.empty?

        PriceRequirement.new(instrument: target_instrument, dates:)
      end
    end

    def rate_requirements(price_requirements = self.price_requirements)
      dates_by_pair = Hash.new { |hash, pair| hash[pair] = Set.new }
      add_price_rate_requirements(dates_by_pair, price_requirements)
      trades.each { |trade| add_trade_rate_requirement(dates_by_pair, trade) }
      actions.each { |action| add_action_rate_requirement(dates_by_pair, action) }

      build_rate_requirements(dates_by_pair)
    end

    def add_price_rate_requirements(dates_by_pair, price_requirements)
      price_requirements.each do |requirement|
        add_dates(dates_by_pair, requirement.instrument.currency, requirement.dates)
      end
    end

    def add_trade_rate_requirement(dates_by_pair, trade)
      base_currency = trade.explicit_settlement_conversion? ? trade.settlement_currency : trade.currency
      add_date(dates_by_pair, base_currency, trade.traded_on)
    end

    def add_action_rate_requirement(dates_by_pair, action)
      cash_action = action.cash_action?
      return unless cash_action || action.cash_in_lieu?

      date = cash_action ? action.performance_on : action.effective_on
      add_date(dates_by_pair, action.currency, date)
    end

    def build_rate_requirements(dates_by_pair)
      dates_by_pair.map do |(base_currency, quote_currency), dates|
        RateRequirement.new(base_currency:, quote_currency:, dates: dates.to_a.sort)
      end
    end

    def add_dates(dates_by_pair, base_currency, dates)
      return if base_currency.blank? || base_currency == reporting_currency

      dates.each { |date| add_date(dates_by_pair, base_currency, date) }
    end

    def add_date(dates_by_pair, base_currency, date)
      return if base_currency.blank? || date.blank? || date > to || base_currency == reporting_currency

      dates_by_pair[[ CurrencyCode.normalize(base_currency), reporting_currency ]] << date
    end

    def instruments
      return [ instrument ] if instrument

      (trades.map(&:instrument) + actions.map(&:instrument)).uniq
    end

    def trades
      @trades ||= begin
        scope = user.trades.where(traded_on: ..to).includes(:instrument).order(:traded_on, :id)
        scope = scope.where(instrument:) if instrument
        scope.to_a
      end
    end

    def actions
      @actions ||= begin
        scope = user.corporate_actions.effective_on_or_before(to).includes(:instrument)
        scope = scope.where(instrument:) if instrument
        scope.to_a
      end
    end

    def open_position_dates(target_instrument)
      instrument_trades = trades_for_instrument(target_instrument)
      return [] if instrument_trades.empty?

      quantities = quantity_timeline_for(target_instrument, instrument_trades)
      open_dates_from_timeline(instrument_trades.first.traded_on, quantities)
    rescue Position::InvalidLongOnlyData, Position::InvalidQuantityActionData
      open_dates_from_trades(instrument_trades)
    end

    def trades_for_instrument(target_instrument)
      trades.select { |trade| trade.instrument == target_instrument }
    end

    def quantity_timeline_for(target_instrument, instrument_trades)
      Position::Calculator.quantity_timeline(
        trades: instrument_trades,
        corporate_actions: quantity_actions_for(target_instrument),
        amount_for: ->(trade) { trade.total_amount },
        cash_in_lieu_amount_for: ->(action) { action.cash_in_lieu_amount.to_d }
      )
    end

    def quantity_actions_for(target_instrument)
      actions.select { |action| action.instrument == target_instrument && action.quantity_action? }
    end

    def open_dates_from_timeline(start_date, quantities)
      start_date = [ start_date, from ].max
      quantity = quantities.select { |date, _| date < start_date }.max_by(&:first)&.last || 0.to_r
      (start_date..to).filter_map do |date|
        quantity = quantities.fetch(date, quantity)
        date if date >= from && quantity.positive?
      end
    end

    def open_dates_from_trades(instrument_trades)
      start_date = [ instrument_trades.first.traded_on, from ].max
      events = instrument_trades.group_by(&:traded_on)
      quantity = quantity_before(start_date, instrument_trades)
      open_dates_for(events, start_date, quantity)
    end

    def quantity_before(start_date, instrument_trades)
      instrument_trades.sum do |trade|
        next 0.to_r if trade.traded_on >= start_date

        quantity = trade.quantity.to_r
        trade.buy? ? quantity : -quantity
      end
    end

    def open_dates_for(events, start_date, initial_quantity)
      quantity = initial_quantity
      (start_date..to).filter_map do |date|
        events.fetch(date, []).each do |trade|
          trade_quantity = trade.quantity.to_r
          quantity += trade.buy? ? trade_quantity : -trade_quantity
        end
        date if date >= from && quantity.positive?
      end
    end

    def fetch(requirement, refetch_full_range:)
      ranges = fetch_ranges(requirement, refetch_full_range:)
      return false if ranges.empty?

      fence = publication_fence_for(requirement)
      generation = fence.capture
      ranges.each { |range| fetch_range(requirement, range, fence:, generation:) }
      true
    end

    def fetch_ranges(requirement, refetch_full_range:)
      dates = requirement.dates
      if refetch_full_range
        range = MarketData::HistoricalObservationWindow.for(dates.min).begin..dates.max
        bounded_ranges([ range ])
      else
        ranges_for(missing_dates(requirement))
      end
    end

    def fetch_range(requirement, range, fence:, generation:)
      progress.call("Fetching #{label_for(requirement)}")
      wait_for_requirement(requirement)
      import_range(requirement, range, fence:, generation:)
    end

    def wait_for_requirement(requirement)
      if requirement.price?
        throttle&.wait!(instrument: requirement.instrument)
      else
        throttle&.wait!
      end
    end

    def import_range(requirement, range, fence:, generation:)
      from_date = range.begin
      to_date = range.end
      if requirement.price?
        price_importer.call(
          instrument: requirement.instrument, from: from_date, to: to_date,
          enqueue_performance_rebuild: false, fence:, generation:
        )
      else
        rate_importer.call(
          base_currency: requirement.base_currency, quote_currency: requirement.quote_currency,
          from: from_date, to: to_date, enqueue_performance_rebuild: false,
          fence:, generation:
        )
      end
    end

    def publication_fence_for(requirement)
      target = if requirement.price?
        MarketData::Target.new(kind: :daily_closing_prices, record_id: requirement.instrument.id,
          provider: PRICE_PROVIDER)
      else
        MarketData::Target.new(kind: :historical_exchange_rates,
          base_currency: requirement.base_currency, quote_currency: requirement.quote_currency,
          provider: RATE_PROVIDER)
      end
      MarketData::PublicationFence.new(target:, cache:)
    end

    def enqueue_performance_rebuilds
      Performance::ObservationInvalidator.enqueue(user:, from:)
      rebuild_instruments.each do |target_instrument|
        attributes = { user:, instrument: target_instrument, from: }
        attributes[:reporting_currency] = reporting_currency if instrument
        Performance::ObservationInvalidator.enqueue_instrument(**attributes)
      end
    end

    def rebuild_instruments
      return [ instrument ] if instrument

      instruments
    end

    def missing_dates(requirement)
      observed_dates = observed_dates_for(requirement)
      observed_dates.sort!
      missing_dates_from(observed_dates, requirement.dates)
    end

    def observed_dates_for(requirement)
      if requirement.price?
        price_observed_dates(requirement)
      else
        rate_observed_dates(requirement)
      end
    end

    def price_observed_dates(requirement)
      DailyClosingPrice.where(
        instrument: requirement.instrument, provider: PRICE_PROVIDER,
        trading_date: observation_range_for(requirement)
      ).pluck(:trading_date)
    end

    def rate_observed_dates(requirement)
      rate_scope(requirement).pluck(:rate_date)
    end

    def rate_scope(requirement)
      base_currency = requirement.base_currency
      quote_currency = requirement.quote_currency
      scope = HistoricalExchangeRate.where(
        provider: RATE_PROVIDER,
        rate_date: observation_range_for(requirement)
      )
      scope.where(
        base_currency:, quote_currency:
      ).or(scope.where(
        base_currency: quote_currency, quote_currency: base_currency
      ))
    end

    def observation_range_for(requirement)
      dates = requirement.dates
      MarketData::HistoricalObservationWindow.for(dates.min).begin..dates.max
    end

    def missing_dates_from(observed_dates, dates)
      observation_index = 0
      latest_observation = nil
      dates.select do |date|
        while observation_index < observed_dates.length && observed_dates[observation_index] <= date
          latest_observation = observed_dates.fetch(observation_index)
          observation_index += 1
        end

        latest_observation.nil? || latest_observation < date - MarketData::HistoricalObservationWindow::MAXIMUM_LOOKBACK_DAYS
      end
    end

    def ranges_for(dates)
      bounded_ranges(coalesced_ranges(dates))
    end

    def coalesced_ranges(dates)
      merge_ranges(initial_ranges(dates))
    end

    def initial_ranges(dates)
      dates.sort.slice_when { |left, right| right != left + 1.day }
        .map { |group| MarketData::HistoricalObservationWindow.for(group.first).begin..group.last }
        .sort_by(&:begin)
    end

    def merge_ranges(ranges)
      ranges.each_with_object([]) { |range, merged| append_range(merged, range) }
    end

    def append_range(ranges, range)
      last_range = ranges.last
      last_end = last_range&.end
      if last_end && range.begin <= last_end + 1.day
        ranges[-1] = last_range.begin..[ last_end, range.end ].max
      else
        ranges << range
      end
    end

    def bounded_ranges(ranges)
      ranges.flat_map do |range|
        bounded = []
        start_date = range.begin
        range_end = range.end
        while start_date <= range_end
          end_date = [ start_date + MAX_RANGE_DAYS, range_end ].min
          bounded << (start_date..end_date)
          start_date = end_date + 1.day
        end
        bounded
      end
    end

    def label_for(requirement)
      return "#{requirement.instrument.ticker} historical closing prices" if requirement.price?

      "#{requirement.base_currency}/#{requirement.quote_currency} historical exchange rates"
    end
  end
end
