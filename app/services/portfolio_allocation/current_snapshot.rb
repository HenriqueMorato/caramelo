module PortfolioAllocation
  class CurrentSnapshot
    Issue = Data.define(:instrument, :kind)
    Holding = Data.define(
      :instrument, :position, :market_price, :valuation, :market_value_amount,
      :quantity, :price_amount
    )
    Result = Data.define(:status, :holdings, :total_amount, :issues) do
      def available? = status == :available
      def empty? = status == :empty
      def incomplete? = status == :incomplete
      def values_available? = total_amount.present? && total_amount.positive?
    end

    def self.for(owner:, reporting_currency: owner.reporting_currency,
      market_price_service: MarketPrice::Service.default,
      exchange_rate_service: ExchangeRate::Service.default)
      new(owner:, reporting_currency:, market_price_service:, exchange_rate_service:).call
    end

    def initialize(owner:, reporting_currency:, market_price_service:, exchange_rate_service:)
      @owner = owner
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
      @market_price_service = market_price_service
      @exchange_rate_service = exchange_rate_service
    end

    def call
      position_results = Position.overview(owner:)
      open_results = position_results.select { |result| result.position&.open? || result.invalid? }
      return Result.new(:empty, [], BigDecimal("0"), []) if open_results.empty?

      holdings = open_results.filter_map { |result| holding_for(result) }
      issues = holdings.filter_map { |holding| issue_for(holding) }
      status = issues.empty? ? :available : :incomplete
      total_amount = holdings.sum(&:market_value_amount) if holdings.all?(&:market_value_amount)
      Result.new(status, holdings, total_amount, issues)
    end

    private

    attr_reader :owner, :reporting_currency, :market_price_service, :exchange_rate_service

    def holding_for(position_result)
      return invalid_holding(position_result.instrument) if position_result.invalid?

      presenter = Position::Presenter.for(
        position_result:, market_price_service:, exchange_rate_service:, reporting_currency:
      )
      position = position_result.position
      valuation = presenter.valuation
      amount = valuation.market_value_amount
      quantity = position.quantity
      price_amount = amount && quantity.positive? ? amount / quantity : nil
      Holding.new(
        position_result.instrument, position, presenter.market_price, valuation,
        amount, quantity, price_amount
      )
    end

    def invalid_holding(instrument)
      Holding.new(instrument, nil, nil, nil, nil, nil, nil)
    end

    def issue_for(holding)
      return Issue.new(holding.instrument, :invalid) unless holding.position
      return Issue.new(holding.instrument, :missing) if holding.valuation&.missing?
      Issue.new(holding.instrument, :stale) if holding.market_price.stale? || holding.valuation.stale?
    end
  end
end
