module Performance
  class ObservationStore
    include ObservationStoreSupport

    UNIQUE_INDEX = "index_portfolio_performance_observations_uniqueness"

    def initialize(user:, reporting_currency: user.reporting_currency)
      @user = user
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
    end

    def write(valuation, source_generation: 0, generated_at: Time.current)
      PortfolioPerformanceObservation.upsert_all(
        [ attributes_for(valuation, source_generation:, generated_at:) ],
        unique_by: UNIQUE_INDEX
      )
    end

    private

    attr_reader :user, :reporting_currency

    def scope
      user.portfolio_performance_observations.where(reporting_currency:)
    end

    def attributes_for(valuation, source_generation:, generated_at:)
      {
        user_id: user.id,
        observed_on: valuation.valuation_date,
        reporting_currency:,
        market_value_amount: serialize_decimal(valuation.market_value_amount),
        net_cash_flow_amount: serialize_decimal(valuation.net_cash_flow_amount),
        **cash_flow_attributes(valuation.cash_flows),
        status: valuation.status,
        source_generation:,
        generated_at:,
        stale_at: nil,
        created_at: generated_at,
        updated_at: generated_at
      }
    end
  end
end
