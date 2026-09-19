module Performance
  class ObservationStore
    UNIQUE_INDEX = "index_portfolio_performance_observations_uniqueness"

    def initialize(user:, reporting_currency: user.reporting_currency)
      @user = user
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
    end

    def read(from:, to:)
      scope.for_range(from:, to:).index_by(&:observed_on)
    end

    def stale_from(observed_on)
      scope.where(observed_on: observed_on..).update_all(stale_at: Time.current, updated_at: Time.current)
    end

    def delete_all
      scope.delete_all
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
        cash_flow_total: valuation.cash_flows.sum { |flow| flow.amount.to_r }.to_r.to_s,
        dated_cash_flow_total: valuation.cash_flows.sum { |flow| flow.amount.to_r * flow.occurred_on.jd }.to_r.to_s,
        status: valuation.status,
        source_generation:,
        generated_at:,
        stale_at: nil,
        created_at: generated_at,
        updated_at: generated_at
      }
    end

    def serialize_decimal(value)
      return if value.nil?

      value.to_d.to_s("F")
    end
  end
end
