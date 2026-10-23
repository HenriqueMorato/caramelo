module Performance
  class AssetTypeChartData
    Aggregate = Data.define(
      :market_value_amount, :cash_flow_total, :dated_cash_flow_total, :status,
      :source_generations, :stale_instrument_ids, :active_instrument_ids
    ) do
      def available? = %i[available stale].include?(status)
    end

    def self.for(series:, user:, reporting_currency: user.reporting_currency)
      new(series:, user:, reporting_currency:).to_a
    end

    def initialize(series:, user:, reporting_currency:)
      @series = series
      @user = user
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
    end

    def to_a
      return [] if dates.empty?

      instruments = performance_instruments
      return [] if instruments.empty?

      records = instrument_observations(instruments)
      instruments_by_type = instruments.group_by(&:asset_type)
      type_labels = AssetType.labels_for(instruments_by_type.keys)
      instruments_by_type.filter_map do |asset_type, grouped_instruments|
        values = values_for(grouped_instruments, records)
        next if values.none? { |value| !value.nil? }

        {
          identifier: asset_type,
          label: type_labels.fetch(AssetType.normalize_key(asset_type)),
          values:
        }
      end
    end

    private

    attr_reader :series, :user, :reporting_currency

    def dates
      @dates ||= series.observations.map(&:date)
    end

    def performance_instruments
      @performance_start_dates ||= begin
        ending_on = series.to
        trade_dates = user.trades.where(traded_on: ..ending_on).group(:instrument_id).minimum(:traded_on)
        action_dates = user.corporate_actions.effective_on_or_before(ending_on)
          .select(:instrument_id, :effective_on, :ex_date, :paid_on)
          .to_a.group_by(&:instrument_id)
          .transform_values { |actions| actions.map(&:performance_on).min }
        trade_dates.merge(action_dates) do |_instrument_id, trade_date, action_date|
          [ trade_date, action_date ].compact.min
        end
      end
      @instruments ||= Instrument.where(id: @performance_start_dates.keys).order(:asset_type, :ticker).to_a
    end

    def instrument_observations(instruments)
      user.instrument_performance_observations
        .where(
          instrument_id: instruments.map(&:id),
          reporting_currency:,
          observed_on: dates.first..dates.last
        )
        .index_by { |observation| [ observation.instrument_id, observation.observed_on ] }
    end

    def values_for(instruments, records)
      aggregates = dates.map { |date| aggregate_for(instruments, date, records) }
      opening_index = aggregates.index { |aggregate| aggregate&.available? }
      return [] unless opening_index

      opening_date = dates.fetch(opening_index)
      opening = aggregates.fetch(opening_index)
      aggregates.each_with_index.map do |aggregate, index|
        next if index < opening_index

        return_ratio_for(
          date: dates.fetch(index), aggregate:, opening_date:, opening:
        )
      end
    end

    def aggregate_for(instruments, date, records)
      active_instruments = instruments.select { |instrument| performance_start_date(instrument) <= date }
      return if active_instruments.empty?

      observations = active_instruments.filter_map { |instrument| records[[ instrument.id, date ]] }
      return missing_aggregate unless observations.length == active_instruments.length
      return missing_aggregate if observations.any?(&:missing?)

      status = observations.any?(&:stale?) ? :stale : :available
      aggregate_values(observations, active_instruments, status)
    end

    def aggregate_values(observations, active_instruments, status)
      observations_by_instrument = observations.to_h { |observation| [ observation.instrument_id, observation ] }
      Aggregate.new(
        observations.sum { |observation| observation.market_value_amount || BigDecimal("0") },
        observations.sum(&:cash_flow_total),
        observations.sum(&:dated_cash_flow_total),
        status,
        observations_by_instrument.transform_values(&:source_generation),
        observations_by_instrument.filter_map { |instrument_id, observation| instrument_id if observation.stale? },
        active_instruments.map(&:id)
      )
    end

    def missing_aggregate
      Aggregate.new(nil, nil, nil, :missing, {}, [], [])
    end

    def performance_start_date(instrument)
      @performance_start_dates.fetch(instrument.id)
    end

    def return_ratio_for(date:, aggregate:, opening_date:, opening:)
      return BigDecimal("0") if date == opening_date
      return unless aggregate&.available?
      return unless comparable_aggregates?(aggregate, opening)

      date_jd = date.jd
      duration = date_jd - opening_date.jd
      return if duration <= 0

      flow = aggregate.cash_flow_total - opening.cash_flow_total
      dated_flow = aggregate.dated_cash_flow_total - opening.dated_cash_flow_total
      opening_market_value = opening.market_value_amount
      weighted_flow = (date_jd * flow - dated_flow) / duration
      capital = opening_market_value.to_r + weighted_flow
      return if capital.zero?

      gain = aggregate.market_value_amount - opening_market_value - flow
      decimal(gain / capital)
    end

    def comparable_aggregates?(aggregate, opening)
      aggregate_generations = aggregate.source_generations
      opening_generations = opening.source_generations
      aggregate_active_instrument_ids = aggregate.active_instrument_ids
      opening_active_instrument_ids = opening.active_instrument_ids
      aggregate_stale_instrument_ids = aggregate.stale_instrument_ids
      opening_stale_instrument_ids = opening.stale_instrument_ids
      instrument_ids = aggregate_generations.keys | opening_generations.keys |
        aggregate_active_instrument_ids | opening_active_instrument_ids
      instrument_ids.all? do |instrument_id|
        opening_generation = opening_generations[instrument_id]
        closing_generation = aggregate_generations[instrument_id]
        next false if closing_generation.nil?
        next true if opening_generation.nil? && !opening_active_instrument_ids.include?(instrument_id)
        next true if opening_generation == closing_generation

        !opening_stale_instrument_ids.include?(instrument_id) &&
          !aggregate_stale_instrument_ids.include?(instrument_id)
      end
    end

    def decimal(value)
      BigDecimal(value.to_r, Position::ANALYTICAL_DECIMAL_PRECISION)
    end
  end
end
