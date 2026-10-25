module InvestmentGoals
  class Progress
    Result = Data.define(
      :goal, :current_amount, :current_value, :target_amount, :target_value,
      :remaining_amount, :remaining_value, :ratio, :status
    ) do
      def available? = %i[available stale].include?(status)
      def unavailable? = status == :unavailable
      def fresh? = status == :available
      def stale? = status == :stale
      def achieved? = fresh? && current_amount >= target_amount
      def percentage = ratio && ratio * 100
    end

    def self.for(goal:, market_value:, market_value_amount: nil, fresh: true)
      new(goal:, market_value:, market_value_amount:, fresh:).calculate
    end

    def initialize(goal:, market_value:, market_value_amount:, fresh:)
      @goal = goal
      @market_value = market_value
      @market_value_amount = market_value_amount
      @fresh = fresh
    end

    def calculate
      return unavailable_result unless usable_market_value?

      current_amount = decimal(market_value_amount || market_value.amount)
      target_amount = goal.target_amount
      remaining_amount = [ target_amount - current_amount, BigDecimal("0") ].max
      Result.new(
        goal:, current_amount:, current_value: market_value,
        target_amount:, target_value: goal.target_value,
        remaining_amount:, remaining_value: Money.from_amount(remaining_amount, goal.reporting_currency),
        ratio: decimal(current_amount / target_amount), status: @fresh ? :available : :stale
      )
    end

    private

    attr_reader :goal, :market_value, :market_value_amount

    def usable_market_value?
      market_value.present? && market_value.currency.iso_code == goal.reporting_currency
    end

    def unavailable_result
      Result.new(
        goal:, current_amount: nil, current_value: nil,
        target_amount: goal.target_amount, target_value: goal.target_value,
        remaining_amount: nil, remaining_value: nil, ratio: nil, status: :unavailable
      )
    end

    def decimal(value)
      BigDecimal(value.to_r, Position::ANALYTICAL_DECIMAL_PRECISION)
    end
  end
end
