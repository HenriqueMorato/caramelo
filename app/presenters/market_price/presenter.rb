module MarketPrice
  class Presenter
    MISSING_LOOKUP = CurrentMarketPriceCache::Lookup.new(current_market_price: nil, status: :missing)

    attr_reader :instrument

    def self.for(instrument:, service: Service.default)
      lookup = service.read(instrument:)
      new(instrument:, lookup:, refreshable: !lookup.nil?)
    end

    def initialize(instrument:, lookup:, refreshable: true)
      @instrument = instrument
      @lookup = lookup || MISSING_LOOKUP
      @refreshable = refreshable
      freeze
    end

    def refreshable?
      @refreshable
    end

    def current_market_price
      lookup.current_market_price
    end

    def fresh?
      lookup.fresh?
    end

    def stale?
      lookup.stale?
    end

    private

    attr_reader :lookup
  end
end
