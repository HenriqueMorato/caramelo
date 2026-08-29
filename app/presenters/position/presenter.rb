class Position
  class Presenter
    attr_reader :position_result, :market_price, :valuation

    delegate :instrument, :position, :error, :invalid?, to: :position_result

    def self.for(position_result:, market_price_service: MarketPrice::Service.default,
      exchange_rate_service: ExchangeRate::Service.default)
      market_price = MarketPrice::Presenter.for(
        instrument: position_result.instrument,
        service: market_price_service
      )
      new(
        position_result:,
        market_price:,
        valuation: Valuation::Current.for(
          position: position_result.position,
          market_price:,
          exchange_rate_service:
        )
      )
    end

    def initialize(position_result:, market_price:, valuation:)
      @position_result = position_result
      @market_price = market_price
      @valuation = valuation
      freeze
    end

    def market_price_refreshable?
      market_price.refreshable?
    end
  end
end
