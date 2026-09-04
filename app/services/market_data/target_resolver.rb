module MarketData
  class TargetResolver
    def self.call(attributes:, owner: User.owner)
      new(attributes:, owner:).call
    end

    def initialize(attributes:, owner:)
      @attributes = attributes.to_h.symbolize_keys
      @owner = owner
    end

    def call
      target = Target.new(**attributes.slice(:kind, :record_id, :base_currency, :quote_currency, :provider))
      validate_owner_scope!(target)
      target
    end

    private

    attr_reader :attributes, :owner

    def validate_owner_scope!(target)
      case target.kind
      when :current_price, :daily_closing_prices
        ensure_traded_instrument!(target)
      when :historical_exchange_rates, :current_exchange_rate
        ensure_traded_currency!(target)
      when :benchmark_observations
        ensure_benchmark!(target)
      when :portfolio_performance
        ensure_reporting_currency!(target)
      end
    end

    def ensure_traded_instrument!(target)
      instrument = Instrument.find(target.record_id)
      return if owner.trades.exists?(instrument:)

      raise ActiveRecord::RecordNotFound
    end

    def ensure_traded_currency!(target)
      currencies = owner.trades.where(currency: [ target.base_currency, target.quote_currency ]).exists?
      raise ActiveRecord::RecordNotFound unless currencies
    end

    def ensure_benchmark!(target)
      MarketBenchmark.find(target.record_id)
    end

    def ensure_reporting_currency!(target)
      return if target.record_id.nil? || target.record_id == owner.id

      raise ActiveRecord::RecordNotFound
    end
  end
end
