module MarketPrice
  class Service
    DEFAULT_PROVIDER = Providers::YahooFinance

    def self.default
      new(provider: DEFAULT_PROVIDER.new, cache: CurrentMarketPriceCache.new)
    end

    def initialize(provider:, cache:)
      @provider = provider
      @cache = cache
    end

    def supports?(instrument:)
      provider.supports?(instrument:)
    end

    def read(instrument:)
      return unless supports?(instrument:)

      cache.read(instrument:, provider: provider.identifier)
    end

    def refresh(instrument:, force: false)
      ensure_supported!(instrument)
      cache.refresh(instrument:, provider: provider.identifier, force:) do
        provider.fetch(instrument:)
      end
    end

    private

    attr_reader :provider, :cache

    def ensure_supported!(instrument)
      return if supports?(instrument:)

      raise UnsupportedInstrument, "instrument #{instrument.id || instrument.ticker} is not supported"
    end
  end
end
