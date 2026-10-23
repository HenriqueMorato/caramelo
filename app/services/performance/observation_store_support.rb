module Performance
  module ObservationStoreSupport
    def read(from:, to:)
      scope.for_range(from:, to:).index_by(&:observed_on)
    end

    def stale_from(observed_on)
      scope.where(observed_on: observed_on..).update_all(stale_at: Time.current, updated_at: Time.current)
    end

    def delete_all
      scope.delete_all
    end

    private

    def cash_flow_attributes(cash_flows)
      {
        cash_flow_total: cash_flows.sum { |flow| flow.amount.to_r }.to_r.to_s,
        dated_cash_flow_total: cash_flows.sum { |flow| flow.amount.to_r * flow.occurred_on.jd }.to_r.to_s
      }
    end

    def serialize_decimal(value)
      value&.to_d&.to_s("F")
    end
  end
end
