module Performance
  class AssetTypeChartData
    Aggregate = Data.define(:market_value_amount, :cash_flow_total, :dated_cash_flow_total, :status) do
      def available? = status == :available
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

      instruments = traded_instruments
      return [] if instruments.empty?

      records = instrument_observations(instruments)
      instruments.group_by(&:asset_type).filter_map do |asset_type, grouped_instruments|
        values = values_for(grouped_instruments, records)
        next if values.none? { |value| !value.nil? }

        {
          identifier: asset_type,
          label: I18n.t("instrument_types.#{asset_type}", default: asset_type.humanize),
          values:
        }
      end
    end

    private

    attr_reader :series, :user, :reporting_currency

    def dates
      @dates ||= series.observations.map(&:date)
    end

    def traded_instruments
      @trade_start_dates ||= user.trades.where(traded_on: ..series.to).group(:instrument_id).minimum(:traded_on)
      @instruments ||= Instrument.where(id: @trade_start_dates.keys).order(:asset_type, :ticker).to_a
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
      active_instruments = instruments.select { |instrument| trade_start_date(instrument) <= date }
      return if active_instruments.empty?

      observations = active_instruments.filter_map { |instrument| records[[ instrument.id, date ]] }
      return Aggregate.new(nil, nil, nil, :missing) unless observations.length == active_instruments.length
      return Aggregate.new(nil, nil, nil, :missing) if observations.any?(&:missing?)

      status = observations.any?(&:stale?) ? :stale : :available
      Aggregate.new(
        observations.sum { |observation| observation.market_value_amount || BigDecimal("0") },
        observations.sum { |observation| observation.cash_flow_total },
        observations.sum { |observation| observation.dated_cash_flow_total },
        status
      )
    end

    def trade_start_date(instrument)
      @trade_start_dates.fetch(instrument.id)
    end

    def return_ratio_for(date:, aggregate:, opening_date:, opening:)
      return BigDecimal("0") if date == opening_date
      return unless aggregate&.available?

      duration = date.jd - opening_date.jd
      return if duration <= 0

      flow = aggregate.cash_flow_total - opening.cash_flow_total
      dated_flow = aggregate.dated_cash_flow_total - opening.dated_cash_flow_total
      weighted_flow = (date.jd * flow - dated_flow) / duration
      capital = opening.market_value_amount.to_r + weighted_flow
      return if capital.zero?

      gain = aggregate.market_value_amount - opening.market_value_amount - flow
      decimal(gain / capital)
    end

    def decimal(value)
      BigDecimal(value.to_r, Position::ANALYTICAL_DECIMAL_PRECISION)
    end
  end
end
