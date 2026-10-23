module Performance
  class Portfolio
    # One dated flow into the holdings in the reporting currency. Purchases are
    # positive contributions; sales and cash distributions are withdrawals.
    CashFlow = Data.define(:occurred_on, :amount, :source)

    # One instrument's replayed holdings. Amounts use the reporting currency:
    # remaining purchase basis, closing market value, realized/unrealized gain,
    # and trade cash flow. A missing status identifies an absent required quote.
    PositionResult = Data.define(
      :instrument, :quantity, :reporting_cost_basis_amount, :market_value_amount,
      :realized_gain_amount, :unrealized_gain_amount, :net_cash_flow_amount,
      :investment_income_amount, :investment_income, :invested_amount,
      :status, :daily_closing_price, :exchange_rate_lookup, :cash_flows
    ) do
      def available? = status != :missing
      def missing?   = status == :missing
      def closed?    = status == :closed
      def market_price_as_of = daily_closing_price&.trading_date

      def total_gain_amount
        return if realized_gain_amount.nil? || unrealized_gain_amount.nil? || investment_income_amount.nil?

        realized_gain_amount + unrealized_gain_amount + investment_income_amount
      end

      def return_ratio
        return if total_gain_amount.nil? || invested_amount.nil? || invested_amount.zero?

        total_gain_amount / invested_amount
      end

      def exchange_rate_as_of
        return if exchange_rate_lookup.nil? || exchange_rate_lookup.same_currency?

        exchange_rate_lookup.exchange_rate&.rate_date
      end
    end

    # Portfolio totals for one reporting date. Monetary objects round only for
    # presentation; their matching *_amount fields retain analytical precision.
    Result = Data.define(
      :valuation_date, :market_value_amount, :market_value,
      :realized_gain_amount, :realized_gain,
      :unrealized_gain_amount, :unrealized_gain,
      :net_cash_flow_amount, :net_cash_flow,
      :investment_income_amount, :investment_income,
      :status, :position_results, :cash_flows
    ) do
      def available? = status != :missing
      def missing?   = status == :missing
      def empty?     = status == :empty

      # Aggregate dates use the oldest observation that contributed to the report.
      def market_price_as_of = position_results.filter_map(&:market_price_as_of).min
      def exchange_rate_as_of = position_results.filter_map(&:exchange_rate_as_of).min
      def market_data_as_of = market_price_as_of
    end

    def self.for(valuation_date:, owner: User.default_owner, instrument: nil, trades: nil, corporate_actions: nil,
      exchange_rate_service: HistoricalExchangeRate::Service.new,
      daily_closing_price_provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier,
      reporting_currency: owner.reporting_currency)
      new(
        valuation_date:, owner:, instrument:, trades:, corporate_actions:, exchange_rate_service:,
        daily_closing_price_provider:, reporting_currency:
      ).calculate
    end

    def initialize(valuation_date:, owner:, instrument:, trades:, corporate_actions:, exchange_rate_service:,
      daily_closing_price_provider:, reporting_currency:)
      @valuation_date = valuation_date
      @owner = owner
      @instrument = instrument
      @trades = trades
      @corporate_actions = corporate_actions
      @exchange_rate_service = exchange_rate_service
      @daily_closing_price_provider = daily_closing_price_provider
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
    end

    def calculate
      validate_valuation_date!
      grouped_trades = trades_by_instrument
      grouped_actions = corporate_actions_by_instrument
      instruments = grouped_trades.keys | grouped_actions.keys
      position_results = instruments.map do |instrument|
        PositionCalculator.new(
          instrument:, trades: grouped_trades.fetch(instrument, []),
          corporate_actions: grouped_actions.fetch(instrument, []),
          valuation_date:, exchange_rate_service:,
          daily_closing_price_provider:, reporting_currency:
        ).calculate
      end
      return missing_result(position_results) if position_results.any?(&:missing?)
      return empty_result if position_results.empty?

      available_result(position_results)
    end

    private

    attr_reader :valuation_date, :owner, :instrument, :trades, :corporate_actions,
      :exchange_rate_service, :daily_closing_price_provider, :reporting_currency

    def trades_by_instrument
      return supplied_trades_by_instrument if self.trades

      trade_scope = owner.trades.strict_loading.where(traded_on: ..valuation_date)
      if instrument
        scoped_trades = trade_scope.where(instrument:).order(:traded_on, :id).to_a
        return {} if scoped_trades.empty?

        return { instrument => scoped_trades }
      end

      trade_scope
        .includes(:instrument)
        .order(:traded_on, :id).to_a.group_by(&:instrument)
    end

    def supplied_trades_by_instrument
      scoped_trades = supplied_trades
      return {} if scoped_trades.empty?

      instrument ? { instrument => scoped_trades } : scoped_trades.group_by(&:instrument)
    end

    def supplied_trades
      scoped_trades = self.trades.select { |trade| trade.user_id == owner.id && trade.traded_on <= valuation_date }
      scoped_trades = scoped_trades.select { |trade| trade.instrument == instrument } if instrument
      scoped_trades.sort_by { |trade| [ trade.traded_on, trade.id ] }
    end

    def corporate_actions_by_instrument
      @corporate_actions_by_instrument ||= begin
        actions = corporate_actions || corporate_action_scope.to_a
        eligible_corporate_actions(actions).group_by(&:instrument)
      end
    end

    def eligible_corporate_actions(actions)
      actions.select do |action|
        action.user_id == owner.id && action.confirmed? && action.performance_on <= valuation_date &&
          (!instrument || action.instrument == instrument)
      end
    end

    def corporate_action_scope
      scope = owner.corporate_actions.effective_on_or_before(valuation_date).includes(:instrument)
      instrument ? scope.where(instrument:) : scope
    end

    def available_result(position_results)
      totals = aggregate_amounts(position_results)

      Result.new(
        valuation_date:, **totals,
        **money_totals(totals),
        status: :available, position_results:,
        cash_flows: position_results.flat_map(&:cash_flows).sort_by(&:occurred_on)
      )
    end

    def aggregate_amounts(position_results)
      %i[
        market_value_amount realized_gain_amount unrealized_gain_amount
        net_cash_flow_amount investment_income_amount
      ].to_h do |amount|
        [ amount, decimal(position_results.sum { |position_result| position_result.public_send(amount) }) ]
      end
    end

    def money_totals(totals)
      {
        market_value: Money.from_amount(totals.fetch(:market_value_amount), reporting_currency),
        realized_gain: Money.from_amount(totals.fetch(:realized_gain_amount), reporting_currency),
        unrealized_gain: Money.from_amount(totals.fetch(:unrealized_gain_amount), reporting_currency),
        net_cash_flow: Money.from_amount(totals.fetch(:net_cash_flow_amount), reporting_currency),
        investment_income: Money.from_amount(totals.fetch(:investment_income_amount), reporting_currency)
      }
    end

    def empty_result
      zero = BigDecimal("0")
      Result.new(
        valuation_date:, market_value_amount: zero, market_value: Money.new(0, reporting_currency),
        realized_gain_amount: zero, realized_gain: Money.new(0, reporting_currency),
        unrealized_gain_amount: zero, unrealized_gain: Money.new(0, reporting_currency),
        net_cash_flow_amount: zero, net_cash_flow: Money.new(0, reporting_currency),
        investment_income_amount: zero, investment_income: Money.new(0, reporting_currency),
        status: :empty, position_results: [], cash_flows: []
      )
    end

    def missing_result(position_results)
      Result.new(
        valuation_date:, market_value_amount: nil, market_value: nil,
        realized_gain_amount: nil, realized_gain: nil,
        unrealized_gain_amount: nil, unrealized_gain: nil,
        net_cash_flow_amount: nil, net_cash_flow: nil,
        investment_income_amount: nil, investment_income: nil,
        status: :missing, position_results:, cash_flows: []
      )
    end

    def decimal(value)
      BigDecimal(value.to_r, Position::ANALYTICAL_DECIMAL_PRECISION)
    end

    def validate_valuation_date!
      return if valuation_date.is_a?(Date) && valuation_date <= Date.current

      raise ArgumentError, "valuation date must be on or before today"
    end
  end
end
