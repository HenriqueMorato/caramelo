class Position
  class Allocation
    Holding = Data.define(:instrument, :amount)
    Entry = Data.define(:identifier, :label, :amount, :ratio, :color_key)
    Result = Data.define(:status, :currency, :type_entries, :position_entries) do
      def available? = status == :available
      def empty? = status == :empty
      def unavailable? = status == :unavailable
    end

    def self.for(positions:, reporting_currency:)
      new(positions:, reporting_currency:).call
    end

    def initialize(positions:, reporting_currency:)
      @positions = positions
      @currency = CurrencyCode.normalize(reporting_currency)
    end

    def call
      return unavailable if positions.any?(&:invalid?)

      open_positions = positions.select { |presenter| presenter.position&.open? }
      return empty if open_positions.empty?
      return unavailable unless open_positions.all? { |presenter| presenter.valuation.available? }

      holdings = open_positions.filter_map do |presenter|
        amount = presenter.valuation.market_value.amount
        next unless amount.positive?

        Holding.new(instrument: presenter.instrument, amount:)
      end
      return empty if holdings.empty?

      total_amount = holdings.sum(&:amount)
      Result.new(
        status: :available,
        currency:,
        type_entries: entries_for(
          holdings.group_by { |holding| holding.instrument.asset_type }, total_amount:, color_prefix: "type"
        ) do |instrument|
          type_label(instrument)
        end,
        position_entries: entries_for(
          holdings.group_by { |holding| holding.instrument.id }, total_amount:, color_prefix: "position"
        ) do |instrument|
          position_label(instrument)
        end
      )
    end

    private

    attr_reader :positions, :currency

    def unavailable
      Result.new(status: :unavailable, currency:, type_entries: [], position_entries: [])
    end

    def empty
      Result.new(status: :empty, currency:, type_entries: [], position_entries: [])
    end

    def entries_for(groups, total_amount:, color_prefix:)
      groups.map do |identifier, holdings|
        amount = holdings.sum(&:amount)
        Entry.new(
          identifier: identifier.to_s,
          label: yield(holdings.first.instrument),
          amount:,
          ratio: BigDecimal(amount.to_r / total_amount.to_r, Position::ANALYTICAL_DECIMAL_PRECISION),
          color_key: "#{color_prefix}:#{identifier}"
        )
      end.sort_by { |entry| [ -entry.amount, entry.label ] }
    end

    def type_label(instrument)
      I18n.t("instrument_types.#{instrument.asset_type}", default: instrument.asset_type.humanize)
    end

    def position_label(instrument)
      instrument.ticker
    end
  end
end
