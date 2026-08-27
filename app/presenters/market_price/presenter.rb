module MarketPrice
  class Presenter
    MISSING_ENTRY = CurrentMarketPriceCache::Entry.new(current_market_price: nil, status: :missing)

    attr_reader :instrument, :entry

    def self.for(instrument:, service: Service.default)
      entry = service.read(instrument:)
      new(instrument:, entry:, refreshable: !entry.nil?)
    end

    def initialize(instrument:, entry:, refreshable: true)
      @instrument = instrument
      @entry = entry || MISSING_ENTRY
      @refreshable = refreshable
      freeze
    end

    def refreshable?
      @refreshable
    end

    def current_market_price
      entry.current_market_price
    end

    def fresh?
      entry.fresh?
    end

    def stale?
      entry.stale?
    end
  end
end
