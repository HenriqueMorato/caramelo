class Position
  class Presenter
    attr_reader :entry, :market_price

    delegate :instrument, :position, :error, :invalid?, to: :entry

    def self.for(entry:, market_price_service: MarketPrice::Service.default)
      new(
        entry:,
        market_price: MarketPrice::Presenter.for(
          instrument: entry.instrument,
          service: market_price_service
        )
      )
    end

    def initialize(entry:, market_price:)
      @entry = entry
      @market_price = market_price
      freeze
    end

    def market_price_refreshable?
      market_price.refreshable?
    end
  end
end
