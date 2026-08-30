module Dashboard
  class Presenter
    attr_reader :positions, :recent_trades, :performance

    def self.for(owner: User.owner, today: Date.current)
      position_results = Position.overview
      new(
        positions: position_results.map { |position_result| Position::Presenter.for(position_result:) },
        recent_trades: owner.trades.includes(:instrument, :institution).reverse_chronological.limit(5),
        performance: Performance::Period.for(from: performance_start(owner, today), to: today)
      )
    end

    def self.performance_start(owner, today)
      owner.trades.minimum(:traded_on) || today
    end
    private_class_method :performance_start

    def initialize(positions:, recent_trades:, performance:)
      @positions = positions
      @recent_trades = recent_trades
      @performance = performance
      freeze
    end

    def open_positions
      positions.select { |position| !position.invalid? && position.position.open? }
    end

    def market_value
      values = open_positions.filter_map { |position| position.valuation.market_value }
      return if values.empty?

      Money.from_amount(values.sum(&:amount), reporting_currency)
    end

    def market_value_available?
      market_value.present?
    end

    def has_trades?
      positions.any?
    end

    def stale_market_data?
      open_positions.any? { |position| position.market_price.stale? || position.valuation.stale? }
    end

    def missing_market_data?
      open_positions.any? { |position| position.valuation.missing? }
    end

    def last_market_data_at
      open_positions.filter_map { |position| position.market_price.current_market_price&.fetched_at }.max
    end

    private

    def reporting_currency
      Rails.configuration.x.local_folio.reporting_currency
    end
  end
end
