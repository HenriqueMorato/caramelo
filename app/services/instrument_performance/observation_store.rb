module InstrumentPerformance
  class ObservationStore
    UNIQUE_INDEX = "index_instrument_performance_observations_uniqueness"
    MONETARY_ATTRIBUTES = %i[
      market_value_amount cost_basis_amount realized_gain_amount
      unrealized_gain_amount net_cash_flow_amount invested_amount
    ].freeze

    def initialize(user:, instrument:, reporting_currency: user.reporting_currency)
      @user = user
      @instrument = instrument
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
      InstrumentPerformanceObservation.upsert_all(
        [ attributes_for(valuation, source_generation:, generated_at:) ],
        unique_by: UNIQUE_INDEX
      )
    end

    private

    attr_reader :user, :instrument, :reporting_currency

    def scope
      user.instrument_performance_observations.where(instrument:, reporting_currency:)
    end

    def attributes_for(valuation, source_generation:, generated_at:)
      {
        user_id: user.id,
        instrument_id: instrument.id,
        observed_on: valuation.valuation_date,
        reporting_currency:,
        **monetary_attributes(valuation),
        **cash_flow_attributes(valuation.cash_flows),
        status: observation_status(valuation),
        source_generation:,
        generated_at:,
        stale_at: nil,
        created_at: generated_at,
        updated_at: generated_at
      }
    end

    def monetary_attributes(valuation)
      return MONETARY_ATTRIBUTES.index_with(nil) if valuation.status.to_sym == :missing
      return MONETARY_ATTRIBUTES.index_with("0") if valuation.status.to_sym == :empty

      result = valuation.position_results.find { |item| item.instrument == instrument }
      raise ArgumentError, "instrument valuation does not contain the requested instrument" unless result

      {
        market_value_amount: serialize_decimal(result.market_value_amount),
        cost_basis_amount: serialize_decimal(result.reporting_cost_basis_amount),
        realized_gain_amount: serialize_decimal(result.realized_gain_amount),
        unrealized_gain_amount: serialize_decimal(result.unrealized_gain_amount),
        net_cash_flow_amount: serialize_decimal(result.net_cash_flow_amount),
        invested_amount: serialize_decimal(result.invested_amount)
      }
    end

    def cash_flow_attributes(cash_flows)
      {
        cash_flow_total: cash_flows.sum { |flow| flow.amount.to_r }.to_r.to_s,
        dated_cash_flow_total: cash_flows.sum { |flow| flow.amount.to_r * flow.traded_on.jd }.to_r.to_s
      }
    end

    def observation_status(valuation)
      valuation.status.to_sym == :empty ? :empty : valuation.status
    end

    def serialize_decimal(value)
      value&.to_d&.to_s("F")
    end
  end
end
