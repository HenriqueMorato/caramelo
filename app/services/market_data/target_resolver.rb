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
      target = Target.new(**attributes.slice(:kind, :record_id, :base_currency, :quote_currency))
      validate_owner_scope!(target)
      target_with_provider(target)
    end

    private

    attr_reader :attributes, :owner

    def validate_owner_scope!(target)
      case target.kind
      when :current_price, :daily_closing_prices
        ensure_traded_instrument!(target)
      when :instrument_performance
        ensure_instrument_performance!(target)
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
      valid_pair = target.quote_currency == owner.reporting_currency &&
        owner.trades.where(currency: target.base_currency).exists?
      raise ActiveRecord::RecordNotFound unless valid_pair
    end

    def ensure_benchmark!(target)
      MarketBenchmark.find(target.record_id)
    end

    def ensure_reporting_currency!(target)
      return if target.record_id.nil? || target.record_id == owner.id

      raise ActiveRecord::RecordNotFound
    end

    def ensure_instrument_performance!(target)
      instrument = Instrument.find(target.record_id)
      raise ActiveRecord::RecordNotFound unless owner.trades.exists?(instrument:)

      currencies = owner.instrument_performance_materializations.where(instrument:).pluck(:reporting_currency)
      currencies |= [ instrument.currency, owner.reporting_currency ]
      raise ActiveRecord::RecordNotFound unless currencies.include?(target.quote_currency)
    end

    def target_with_provider(target)
      provider = case target.kind
      when :current_price, :daily_closing_prices
        MarketData::YahooFinance::MARKET_CONFIGURATION.identifier
      when :current_exchange_rate, :historical_exchange_rates
        MarketData::YahooFinance::FX_CONFIGURATION.identifier
      when :benchmark_observations
        MarketBenchmark.find(target.record_id).provider
      end
      Target.new(**target.to_h, provider:)
    end
  end
end
