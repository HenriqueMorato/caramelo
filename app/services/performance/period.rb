module Performance
  class Period
    # Return calculations compare end-of-day values. Trade cash flows after
    # `from` are weighted by their remaining days in the period (Modified Dietz).
    Result = Data.define(
      :from, :to, :opening_valuation, :closing_valuation, :cash_flows,
      :net_cash_flow_amount, :net_cash_flow,
      :gain_loss_amount, :gain_loss,
      :return_ratio, :status
    ) do
      def available? = status != :missing
      def missing?   = status == :missing
      def empty?     = status == :empty
      def return_available? = return_ratio.present?

      def missing_instruments
        [ opening_valuation, closing_valuation ].compact.flat_map(&:position_results)
          .select(&:missing?).map(&:instrument).uniq
      end
    end

    def self.for(from:, to:, portfolio: Portfolio, owner: User.owner, instrument: nil)
      new(from:, to:, portfolio:, owner:, instrument:).calculate
    end

    def initialize(from:, to:, portfolio:, owner:, instrument:)
      @from = from
      @to = to
      @portfolio = portfolio
      @owner = owner
      @instrument = instrument
    end

    def calculate
      validate_range!
      @opening_valuation = valuation_for(from)
      @closing_valuation = valuation_for(to)
      return missing_result if opening_valuation.missing? || closing_valuation.missing?

      @cash_flows = closing_valuation.cash_flows.select do |cash_flow|
        cash_flow.occurred_on > from && cash_flow.occurred_on <= to
      end
      @net_cash_flow_amount = decimal(cash_flows.sum(&:amount))
      @gain_loss_amount = decimal(closing_valuation.market_value_amount - opening_valuation.market_value_amount - net_cash_flow_amount)
      status = opening_valuation.empty? && closing_valuation.empty? ? :empty : :available

      Result.new(
        from:, to:, opening_valuation:, closing_valuation:, cash_flows:,
        net_cash_flow_amount:, net_cash_flow: Money.from_amount(net_cash_flow_amount, reporting_currency),
        gain_loss_amount:, gain_loss: Money.from_amount(gain_loss_amount, reporting_currency),
        return_ratio:, status:
      )
    end

    private

    attr_reader :from, :to, :portfolio, :owner, :instrument, :opening_valuation, :closing_valuation,
      :cash_flows, :net_cash_flow_amount, :gain_loss_amount

    def valuation_for(date)
      attributes = { valuation_date: date, owner: }
      attributes[:instrument] = instrument if instrument
      portfolio.for(**attributes)
    end

    def reporting_currency
      closing_valuation.market_value.currency
    end

    def missing_result
      Result.new(
        from:, to:, opening_valuation:, closing_valuation:, cash_flows: [],
        net_cash_flow_amount: nil, net_cash_flow: nil, gain_loss_amount: nil, gain_loss: nil,
        return_ratio: nil, status: :missing
      )
    end

    def return_ratio
      return if from == to

      weighted_capital = opening_valuation.market_value_amount.to_r + cash_flows.sum do |cash_flow|
        cash_flow.amount.to_r * (to - cash_flow.occurred_on).to_i / (to - from).to_i
      end
      return if weighted_capital.zero?

      decimal(gain_loss_amount / weighted_capital)
    end

    def decimal(value)
      BigDecimal(value.to_r, Position::ANALYTICAL_DECIMAL_PRECISION)
    end

    def validate_range!
      unless from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current
        raise ArgumentError, "period must use dates from the past in chronological order"
      end
    end
  end
end
