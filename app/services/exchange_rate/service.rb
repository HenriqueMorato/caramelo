module ExchangeRate
  class Service
    DEFAULT_PROVIDER = Providers::YahooFinance

    def self.default
      Current.exchange_rate_service ||= new(provider: DEFAULT_PROVIDER.new, cache: ExchangeRateCache.new)
    end

    def initialize(provider:, cache:)
      @provider = provider
      @cache = cache
    end

    def read(base_currency:, quote_currency:)
      return same_currency_lookup if base_currency == quote_currency

      cache.read(base_currency:, quote_currency:, provider: provider.identifier)
    end

    def refresh(base_currency:, quote_currency:, force: false)
      return same_currency_lookup if base_currency == quote_currency

      cache.refresh(base_currency:, quote_currency:, provider: provider.identifier, force:) do
        provider.fetch(base_currency:, quote_currency:)
      end
    end

    private

    attr_reader :provider, :cache

    def same_currency_lookup
      ExchangeRateCache::Lookup.new(exchange_rate: nil, status: :same_currency)
    end
  end
end
