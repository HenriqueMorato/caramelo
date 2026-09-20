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

    def self.for(valuation_date:, owner: User.owner, instrument: nil, trades: nil, corporate_actions: nil,
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
      scoped_trades = self.trades.select { |trade| trade.user_id == owner.id && trade.traded_on <= valuation_date }
      scoped_trades = scoped_trades.select { |trade| trade.instrument == instrument } if instrument
      scoped_trades.sort_by! { |trade| [ trade.traded_on, trade.id ] }
      return {} if scoped_trades.empty?

      instrument ? { instrument => scoped_trades } : scoped_trades.group_by(&:instrument)
    end

    def corporate_actions_by_instrument
      @corporate_actions_by_instrument ||= begin
        actions = corporate_actions || corporate_action_scope.to_a
        actions.select do |action|
          action.user_id == owner.id && action.confirmed? && action.performance_on <= valuation_date &&
            (!instrument || action.instrument == instrument)
        end.group_by(&:instrument)
      end
    end

    def corporate_action_scope
      scope = owner.corporate_actions.effective_on_or_before(valuation_date).includes(:instrument)
      instrument ? scope.where(instrument:) : scope
    end

    def available_result(position_results)
      amounts = %i[
        market_value_amount realized_gain_amount unrealized_gain_amount
        net_cash_flow_amount investment_income_amount
      ]
      totals = amounts.to_h do |amount|
        [ amount, decimal(position_results.sum { |position_result| position_result.public_send(amount) }) ]
      end

      Result.new(
        valuation_date:, **totals,
        market_value: Money.from_amount(totals.fetch(:market_value_amount), reporting_currency),
        realized_gain: Money.from_amount(totals.fetch(:realized_gain_amount), reporting_currency),
        unrealized_gain: Money.from_amount(totals.fetch(:unrealized_gain_amount), reporting_currency),
        net_cash_flow: Money.from_amount(totals.fetch(:net_cash_flow_amount), reporting_currency),
        investment_income: Money.from_amount(totals.fetch(:investment_income_amount), reporting_currency),
        status: :available, position_results:,
        cash_flows: position_results.flat_map(&:cash_flows).sort_by(&:occurred_on)
      )
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

    class PositionCalculator
      def initialize(instrument:, trades:, corporate_actions:, valuation_date:, exchange_rate_service:,
        daily_closing_price_provider:, reporting_currency:)
        @instrument = instrument
        @trades = trades
        @corporate_actions = corporate_actions
        @valuation_date = valuation_date
        @exchange_rate_service = exchange_rate_service
        @daily_closing_price_provider = daily_closing_price_provider
        @reporting_currency = reporting_currency
        @exchange_rates = RateLookupCache.new(exchange_rate_service)
      end

      def calculate
        state = replay_trades
        return missing_result if state.nil?
        return closed_result(state) if state.calculation.quantity.zero?

        daily_closing_price = find_daily_closing_price
        return missing_result(daily_closing_price:) unless daily_closing_price

        rate_lookup = exchange_rates.read(
          base_currency: daily_closing_price.currency,
          quote_currency: reporting_currency,
          rate_date: valuation_date
        )
        return missing_result(daily_closing_price:, exchange_rate_lookup: rate_lookup) unless rate_lookup.available?

        market_value = state.calculation.quantity * daily_closing_price.close_price.to_r * rate_lookup.exchange_rate.rate.to_r
        available_result(state, market_value, daily_closing_price:, exchange_rate_lookup: rate_lookup)
      end

      private

      attr_reader :instrument, :trades, :corporate_actions, :valuation_date, :daily_closing_price_provider,
        :reporting_currency, :exchange_rates

      # Replay combines the shared moving-average calculation with the
      # reporting-currency trade cash flow that is specific to performance.
      Replay = Data.define(
        :calculation, :net_cash_flow, :investment_income, :invested_amount, :cash_flows
      )

      def replay_trades
        reporting_amounts = trades.to_h do |trade|
          settlement = Trades::SettlementValue.for(
            trade:, reporting_currency:, exchange_rates:
          )
          return unless settlement.available?

          [ trade, settlement.amount ]
        end
        quantity_actions = corporate_actions.select(&:quantity_action?)
        cash_in_lieu_amounts = quantity_actions.select(&:cash_in_lieu?).to_h do |action|
          proceeds = CorporateActions::CashInLieuValue.for(
            corporate_action: action, reporting_currency:, exchange_rates:
          )
          return unless proceeds.available?

          [ action, proceeds.amount ]
        end
        calculation = Position::Calculator.for(
          trades:, amount_for: reporting_amounts.method(:fetch), corporate_actions: quantity_actions,
          cash_in_lieu_amount_for: cash_in_lieu_amounts.method(:fetch)
        )
        trade_cash_flows = reporting_amounts.map do |trade, amount|
          amounts_by_side = { "buy" => amount, "sell" => -amount }
          CashFlow.new(occurred_on: trade.traded_on, amount: amounts_by_side.fetch(trade.side), source: :trade)
        end
        income_amounts = corporate_actions.select(&:cash_action?).to_h do |action|
          distribution = CorporateActions::CashDistributionValue.for(
            corporate_action: action, reporting_currency:, exchange_rates:
          )
          return unless distribution.available?

          [ action, distribution.amount ]
        end
        income_cash_flows = income_amounts.map do |action, amount|
          CashFlow.new(occurred_on: action.performance_on, amount: -amount, source: :corporate_action)
        end
        cash_in_lieu_flows = cash_in_lieu_amounts.map do |action, amount|
          CashFlow.new(occurred_on: action.effective_on, amount: -amount, source: :cash_in_lieu)
        end
        Replay.new(
          calculation:, net_cash_flow: trade_cash_flows.sum(&:amount) - cash_in_lieu_amounts.sum(&:last),
          investment_income: income_amounts.sum(&:last),
          invested_amount: reporting_amounts.sum { |trade, amount| trade.buy? ? amount : 0 },
          cash_flows: trade_cash_flows + income_cash_flows + cash_in_lieu_flows
        )
      end

      def find_daily_closing_price
        DailyClosingPrice.where(instrument:, provider: daily_closing_price_provider)
          .where(trading_date: MarketData::HistoricalObservationWindow.for(valuation_date))
          .order(trading_date: :desc)
          .first
      end

      def available_result(state, market_value, daily_closing_price:, exchange_rate_lookup:)
        reporting_cost_basis = decimal(state.calculation.cost_basis_amount)
        market_value_amount = decimal(market_value)
        PositionResult.new(
          instrument:, quantity: decimal(state.calculation.quantity), reporting_cost_basis_amount: reporting_cost_basis,
          market_value_amount:, realized_gain_amount: decimal(state.calculation.realized_gain_amount),
          unrealized_gain_amount: decimal(market_value - state.calculation.cost_basis_amount),
          net_cash_flow_amount: decimal(state.net_cash_flow),
          investment_income_amount: decimal(state.investment_income),
          investment_income: Money.from_amount(decimal(state.investment_income), reporting_currency),
          invested_amount: decimal(state.invested_amount), status: :available,
          daily_closing_price:, exchange_rate_lookup:, cash_flows: state.cash_flows
        )
      end

      def closed_result(state)
        zero = BigDecimal("0")
        PositionResult.new(
          instrument:, quantity: zero, reporting_cost_basis_amount: zero, market_value_amount: zero,
          realized_gain_amount: decimal(state.calculation.realized_gain_amount), unrealized_gain_amount: zero,
          net_cash_flow_amount: decimal(state.net_cash_flow),
          investment_income_amount: decimal(state.investment_income),
          investment_income: Money.from_amount(decimal(state.investment_income), reporting_currency),
          invested_amount: decimal(state.invested_amount), status: :closed,
          daily_closing_price: nil, exchange_rate_lookup: nil, cash_flows: state.cash_flows
        )
      end

      def missing_result(daily_closing_price: nil, exchange_rate_lookup: nil)
        PositionResult.new(
          instrument:, quantity: nil, reporting_cost_basis_amount: nil, market_value_amount: nil,
          realized_gain_amount: nil, unrealized_gain_amount: nil, net_cash_flow_amount: nil,
          investment_income_amount: nil, investment_income: nil, invested_amount: nil,
          status: :missing, daily_closing_price:, exchange_rate_lookup:, cash_flows: []
        )
      end

      def decimal(value)
        BigDecimal(value, Position::ANALYTICAL_DECIMAL_PRECISION)
      end

      class RateLookupCache
        def initialize(service)
          @service = service
          @lookups = {}
        end

        def read(base_currency:, quote_currency:, rate_date:)
          key = [ base_currency, quote_currency, rate_date ]
          @lookups[key] ||= @service.read(base_currency:, quote_currency:, rate_date:)
        end
      end
    end
  end
end
