module MarketPrice
  class Broadcaster
    STREAM_NAME = "current_market_price"
    PARTIAL = "current_market_prices/current_market_price"

    def initialize(service: Service.default)
      @service = service
    end

    def refreshing(instrument:)
      broadcast(instrument:, entry: service.read(instrument:), refreshing: true)
    end

    def current(instrument:)
      broadcast(instrument:, entry: service.read(instrument:), refreshing: false)
    end

    private

    attr_reader :service

    def broadcast(instrument:, entry:, refreshing:)
      market_price = Presenter.new(instrument:, entry:)

      Turbo::StreamsChannel.broadcast_replace_to(
        STREAM_NAME,
        instrument,
        target: ActionView::RecordIdentifier.dom_id(instrument, :current_market_price),
        partial: PARTIAL,
        locals: { market_price:, refreshing:, broadcast: true }
      )
    end
  end
end
