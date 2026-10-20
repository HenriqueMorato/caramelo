module Performance
  class HistoricalDependencyFetcher
    PRICE_PROVIDER = MarketData::YahooFinance::MARKET_CONFIGURATION.identifier
    RATE_PROVIDER = MarketData::YahooFinance::FX_CONFIGURATION.identifier

    PriceRequirement = Data.define(:instrument, :dates)
    RateRequirement = Data.define(:base_currency, :quote_currency, :dates)
    MissingDependency = Data.define(:label, :dates)

    class Unavailable < StandardError
      attr_reader :dependencies

      def initialize(dependencies)
        @dependencies = dependencies
        details = dependencies.map { |dependency| "#{dependency.label} missing for #{format_ranges(dependency.dates)}" }
        super("Historical data remains unavailable: #{details.join('; ')}")
      end

      private

      def format_ranges(dates)
        ranges = dates.sort.slice_when { |left, right| right != left + 1.day }
          .map { |group| group.first..group.last }
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end
    end

    def self.call(user:, reporting_currency:, from:, to:, instrument: nil, price_importer: DailyClosingPrice::Importer.default,
      rate_importer: HistoricalExchangeRate::Importer.default, progress: nil, refetch_full_range: false,
      enqueue_performance_rebuilds: true)
      new(user:, instrument:, reporting_currency:, price_importer:, rate_importer:, progress:,
        enqueue_performance_rebuilds:)
        .call(from:, to:, refetch_full_range:)
    end

    def initialize(user:, reporting_currency:, instrument: nil, price_importer: DailyClosingPrice::Importer.default,
      rate_importer: HistoricalExchangeRate::Importer.default, progress: nil, enqueue_performance_rebuilds: true)
      @user = user
      @instrument = instrument
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
      @price_importer = price_importer
      @rate_importer = rate_importer
      @progress = progress || ->(_message) { }
      @enqueue_performance_rebuilds = enqueue_performance_rebuilds
    end

    def call(from:, to:, refetch_full_range: false)
      validate_range!(from:, to:)
      @from = from
      @to = to
      requirements = price_requirements + rate_requirements
      fetched = requirements.map { |requirement| fetch(requirement, refetch_full_range:) }.any?

      missing = requirements.filter_map do |requirement|
        dates = missing_dates(requirement)
        next if dates.empty?

        MissingDependency.new(label: label_for(requirement), dates:)
      end
      raise Unavailable, missing if missing.any?
      enqueue_performance_rebuilds if fetched && @enqueue_performance_rebuilds

      requirements
    end

    private

    attr_reader :user, :instrument, :reporting_currency, :price_importer, :rate_importer, :progress, :from, :to

    def validate_range!(from:, to:)
      return if from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current

      raise ArgumentError, "dependency range must use past dates in chronological order"
    end

    def price_requirements
      instruments.filter_map do |target_instrument|
        dates = open_position_dates(target_instrument)
        next if dates.empty?

        PriceRequirement.new(instrument: target_instrument, dates:)
      end
    end

    def rate_requirements
      dates_by_pair = Hash.new { |hash, pair| hash[pair] = Set.new }
      price_requirements.each do |requirement|
        add_dates(dates_by_pair, requirement.instrument.currency, requirement.dates)
      end
      trades.each do |trade|
        base_currency = trade.explicit_settlement_conversion? ? trade.settlement_currency : trade.currency
        add_date(dates_by_pair, base_currency, trade.traded_on)
      end
      actions.each do |action|
        if action.cash_action?
          add_date(dates_by_pair, action.currency, action.performance_on)
        elsif action.cash_in_lieu?
          add_date(dates_by_pair, action.currency, action.effective_on)
        end
      end

      dates_by_pair.map do |(base_currency, quote_currency), dates|
        RateRequirement.new(
          base_currency:, quote_currency:, dates: dates.to_a.sort
        )
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
      instrument_trades = trades.select { |trade| trade.instrument == target_instrument }
      return [] if instrument_trades.empty?

      instrument_actions = actions.select do |action|
        action.instrument == target_instrument && action.quantity_action?
      end
      quantities = Position::Calculator.quantity_timeline(
        trades: instrument_trades,
        corporate_actions: instrument_actions,
        amount_for: ->(trade) { trade.total_amount },
        cash_in_lieu_amount_for: ->(action) { action.cash_in_lieu_amount.to_d }
      )
      open_dates_from_timeline(instrument_trades.first.traded_on, quantities)
    rescue Position::InvalidLongOnlyData, Position::InvalidQuantityActionData
      open_dates_from_trades(instrument_trades)
    end

    def open_dates_from_timeline(start_date, quantities)
      quantity = 0.to_r
      (start_date..to).filter_map do |date|
        quantity = quantities.fetch(date, quantity)
        date if date >= from && quantity.positive?
      end
    end

    def open_dates_from_trades(instrument_trades)
      events = instrument_trades.group_by(&:traded_on)
      quantity = 0.to_r
      (instrument_trades.first.traded_on..to).filter_map do |date|
        events.fetch(date, []).each { |trade| quantity += trade.buy? ? trade.quantity.to_r : -trade.quantity.to_r }
        date if date >= from && quantity.positive?
      end
    end

    def fetch(requirement, refetch_full_range:)
      missing = missing_dates(requirement)
      ranges = if refetch_full_range
        [ MarketData::HistoricalObservationWindow.for(requirement.dates.min).begin..requirement.dates.max ]
      else
        ranges_for(missing)
      end
      return false if ranges.empty?

      ranges.each do |range|
        progress.call("Fetching #{label_for(requirement)}")
        if requirement.is_a?(PriceRequirement)
          price_importer.call(
            instrument: requirement.instrument, from: range.begin, to: range.end,
            enqueue_performance_rebuild: false
          )
        else
          rate_importer.call(
            base_currency: requirement.base_currency, quote_currency: requirement.quote_currency,
            from: range.begin, to: range.end, enqueue_performance_rebuild: false
          )
        end
      end
      true
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
      observed_dates = if requirement.is_a?(PriceRequirement)
        DailyClosingPrice.where(
          instrument: requirement.instrument, provider: PRICE_PROVIDER,
          trading_date: MarketData::HistoricalObservationWindow.for(requirement.dates.min).begin..requirement.dates.max
        ).pluck(:trading_date)
      else
        HistoricalExchangeRate.where(
          provider: RATE_PROVIDER,
          rate_date: MarketData::HistoricalObservationWindow.for(requirement.dates.min).begin..requirement.dates.max
        ).where(
          base_currency: requirement.base_currency, quote_currency: requirement.quote_currency
        ).or(
          HistoricalExchangeRate.where(
            provider: RATE_PROVIDER, rate_date: MarketData::HistoricalObservationWindow.for(requirement.dates.min).begin..requirement.dates.max,
            base_currency: requirement.quote_currency, quote_currency: requirement.base_currency
          )
        ).pluck(:rate_date)
      end
      requirement.dates.reject do |date|
        observed_dates.any? do |observed_date|
          MarketData::HistoricalObservationWindow.for(date).cover?(observed_date) && observed_date <= date
        end
      end
    end

    def ranges_for(dates)
      dates.sort.slice_when { |left, right| right != left + 1.day }
        .map { |group| MarketData::HistoricalObservationWindow.for(group.first).begin..group.last }
        .sort_by(&:begin)
        .each_with_object([]) do |range, ranges|
          if ranges.any? && range.begin <= ranges.last.end + 1.day
            ranges[-1] = ranges.last.begin..[ ranges.last.end, range.end ].max
          else
            ranges << range
          end
        end
    end

    def label_for(requirement)
      return "#{requirement.instrument.ticker} historical closing prices" if requirement.is_a?(PriceRequirement)

      "#{requirement.base_currency}/#{requirement.quote_currency} historical exchange rates"
    end
  end
end
