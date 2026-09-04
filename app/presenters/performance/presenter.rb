module Performance
  class Presenter
    include FinancialDisplay

    attr_reader :performance, :result

    def self.for(performance:, pending:)
      new(performance:, result: performance.position_results.first, pending:)
    end

    def initialize(performance:, result:, pending:)
      @performance = performance
      @result = result
      @pending = pending
      freeze
    end

    def empty?
      performance.empty?
    end

    def loading?
      pending && (performance.missing? || result.nil? || result.missing?)
    end

    def unavailable?
      !empty? && !loading? && (performance.missing? || result.nil? || result.missing?)
    end

    def market_data_as_of
      result&.market_price_as_of
    end

    def exchange_rate_as_of
      result&.exchange_rate_as_of
    end

    def cost_basis
      money(result&.reporting_cost_basis_amount)
    end

    def market_value
      money(result&.market_value_amount)
    end

    def realized_gain
      money(result&.realized_gain_amount)
    end

    def realized_gain_label
      signed_money(realized_gain)
    end

    def realized_gain?
      realized_gain.present? && !realized_gain.zero?
    end

    def unrealized_gain
      money(result&.unrealized_gain_amount)
    end

    def unrealized_gain_label
      signed_money(unrealized_gain)
    end

    def unrealized_gain_arrow
      trend_arrow(unrealized_gain)
    end

    def unrealized_gain_color_class
      trend_color_class(unrealized_gain)
    end

    def return_ratio
      result&.return_ratio
    end

    def return_label
      signed_percentage(return_ratio)
    end

    def return_color_class
      trend_color_class(return_ratio)
    end

    private

    attr_reader :pending

    def money(amount)
      return unless amount

      Money.from_amount(amount, reporting_currency)
    end

    def reporting_currency
      performance.market_value.currency
    end
  end
end
