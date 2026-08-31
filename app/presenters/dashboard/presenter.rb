module Dashboard
  class Presenter
    attr_reader :positions, :recent_trades, :performance

    def self.for(owner: User.owner, today: Date.current)
      position_results = Position.overview(owner:)
      new(
        owner:,
        positions: position_results.map { |position_result| Position::Presenter.for(position_result:) },
        recent_trades: owner.trades.includes(:instrument).reverse_chronological.limit(2),
        performance: Performance::Period.for(from: performance_start(owner, today), to: today)
      )
    end

    def self.performance_start(owner, today)
      owner.trades.minimum(:traded_on) || today
    end
    private_class_method :performance_start

    def initialize(owner: User.owner, positions:, recent_trades:, performance:)
      @owner = owner
      @positions = positions
      @recent_trades = recent_trades
      @performance = performance
      freeze
    end

    def day_change
      return unless market_value_available?

      previous_value = previous_business_day_value
      previous_value && market_value - previous_value
    end

    def day_change_ratio
      change = day_change
      return unless change

      previous_value = market_value - change
      return if previous_value.zero?

      BigDecimal(change.amount.to_r / previous_value.amount.to_r, Position::ANALYTICAL_DECIMAL_PRECISION)
    end

    def unrealized_return
      performance&.closing_valuation&.unrealized_gain if performance&.available?
    end

    def open_positions
      positions.select { |position| !position.invalid? && position.position.open? }
    end

    def top_positions
      open_positions.sort_by { |position| -(position.valuation.market_value&.amount || 0) }.first(4)
    end

    def market_value
      return Money.from_amount(0, reporting_currency) if no_open_positions?
      return if !market_value_available?

      values = open_positions.filter_map { |position| position.valuation.market_value }

      Money.from_amount(values.sum(&:amount), reporting_currency)
    end

    def market_value_available?
      open_positions.any? && open_positions.all? { |position| position.valuation.market_value.present? }
    end

    def has_trades?
      positions.any?
    end

    def no_open_positions?
      has_trades? && positions.all? { |position| !position.invalid? && position.position.closed? }
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

    attr_reader :owner

    def reporting_currency
      Rails.configuration.x.local_folio.reporting_currency
    end

    def previous_business_day_value
      dates = DailyClosingPrice.where(instrument: open_positions.map(&:instrument), provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier)
        .distinct.order(trading_date: :desc).limit(2).pluck(:trading_date)
      previous_date = dates.second
      return unless previous_date

      valuation = Performance::Portfolio.for(valuation_date: previous_date, owner:)
      valuation.market_value if valuation.available?
    end
  end
end
