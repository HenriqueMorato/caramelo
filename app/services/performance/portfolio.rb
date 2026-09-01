module Performance
  class Portfolio
    # One trade's signed flow into the holdings in the reporting currency.
    # Purchases are positive contributions and sales are negative withdrawals.
    CashFlow = Data.define(:traded_on, :amount)

    # One instrument's replayed holdings. Amounts use the reporting currency:
    # remaining purchase basis, closing market value, realized/unrealized gain,
    # and trade cash flow. A missing status identifies an absent required quote.
    PositionResult = Data.define(
      :instrument, :quantity, :reporting_cost_basis_amount, :market_value_amount,
      :realized_gain_amount, :unrealized_gain_amount, :net_cash_flow_amount,
      :invested_amount, :status, :daily_closing_price, :exchange_rate_lookup, :cash_flows
    ) do
      def available? = status != :missing
      def missing?   = status == :missing
      def closed?    = status == :closed
      def market_price_as_of = daily_closing_price&.trading_date

      def total_gain_amount
        return if realized_gain_amount.nil? || unrealized_gain_amount.nil?

        realized_gain_amount + unrealized_gain_amount
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

    def self.for(valuation_date:, owner: User.owner, instrument: nil, trades: nil, exchange_rate_service: HistoricalExchangeRate::Service.new,
      daily_closing_price_provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier,
      reporting_currency: Rails.configuration.x.local_folio.reporting_currency)
      new(
        valuation_date:, owner:, instrument:, trades:, exchange_rate_service:, daily_closing_price_provider:,
        reporting_currency:
      ).calculate
    end

    def initialize(valuation_date:, owner:, instrument:, trades:, exchange_rate_service:, daily_closing_price_provider:, reporting_currency:)
      @valuation_date = valuation_date
      @owner = owner
      @instrument = instrument
      @trades = trades
      @exchange_rate_service = exchange_rate_service
      @daily_closing_price_provider = daily_closing_price_provider
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
    end

    def calculate
      validate_valuation_date!
      position_results = trades_by_instrument.map do |instrument, trades|
        PositionCalculator.new(
          instrument:, trades:, valuation_date:, exchange_rate_service:,
          daily_closing_price_provider:, reporting_currency:
        ).calculate
      end
      return missing_result(position_results) if position_results.any?(&:missing?)
      return empty_result if position_results.empty?

      available_result(position_results)
    end

    private

    attr_reader :valuation_date, :owner, :instrument, :trades, :exchange_rate_service, :daily_closing_price_provider, :reporting_currency

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

    def available_result(position_results)
      amounts = %i[market_value_amount realized_gain_amount unrealized_gain_amount net_cash_flow_amount]
      totals = amounts.to_h do |amount|
        [ amount, decimal(position_results.sum { |position_result| position_result.public_send(amount) }) ]
      end

      Result.new(
        valuation_date:, **totals,
        market_value: Money.from_amount(totals.fetch(:market_value_amount), reporting_currency),
        realized_gain: Money.from_amount(totals.fetch(:realized_gain_amount), reporting_currency),
        unrealized_gain: Money.from_amount(totals.fetch(:unrealized_gain_amount), reporting_currency),
        net_cash_flow: Money.from_amount(totals.fetch(:net_cash_flow_amount), reporting_currency),
        status: :available, position_results:, cash_flows: position_results.flat_map(&:cash_flows).sort_by(&:traded_on)
      )
    end

    def empty_result
      zero = BigDecimal("0")
      Result.new(
        valuation_date:, market_value_amount: zero, market_value: Money.new(0, reporting_currency),
        realized_gain_amount: zero, realized_gain: Money.new(0, reporting_currency),
        unrealized_gain_amount: zero, unrealized_gain: Money.new(0, reporting_currency),
        net_cash_flow_amount: zero, net_cash_flow: Money.new(0, reporting_currency),
        status: :empty, position_results: [], cash_flows: []
      )
    end

    def missing_result(position_results)
      Result.new(
        valuation_date:, market_value_amount: nil, market_value: nil,
        realized_gain_amount: nil, realized_gain: nil,
        unrealized_gain_amount: nil, unrealized_gain: nil,
        net_cash_flow_amount: nil, net_cash_flow: nil,
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
      def initialize(instrument:, trades:, valuation_date:, exchange_rate_service:, daily_closing_price_provider:, reporting_currency:)
        @instrument = instrument
        @trades = trades
        @valuation_date = valuation_date
        @exchange_rate_service = exchange_rate_service
        @daily_closing_price_provider = daily_closing_price_provider
        @reporting_currency = reporting_currency
        @exchange_rate_lookups = {}
      end

      def calculate
        state = replay_trades
        return missing_result if state.nil?
        return closed_result(state) if state.calculation.quantity.zero?

        daily_closing_price = find_daily_closing_price
        return missing_result(daily_closing_price:) unless daily_closing_price

        rate_lookup = exchange_rate_for(daily_closing_price.currency, valuation_date)
        return missing_result(daily_closing_price:, exchange_rate_lookup: rate_lookup) unless rate_lookup.available?

        market_value = state.calculation.quantity * daily_closing_price.close_price.to_r * rate_lookup.exchange_rate.rate.to_r
        available_result(state, market_value, daily_closing_price:, exchange_rate_lookup: rate_lookup)
      end

      private

      attr_reader :instrument, :trades, :valuation_date, :exchange_rate_service, :daily_closing_price_provider, :reporting_currency

      # Replay combines the shared moving-average calculation with the
      # reporting-currency trade cash flow that is specific to performance.
      Replay = Data.define(:calculation, :net_cash_flow, :invested_amount, :cash_flows)

      def replay_trades
        reporting_amounts = trades.to_h do |trade|
          rate_lookup = exchange_rate_for(trade.currency, trade.traded_on)
          return unless rate_lookup.available?

          [ trade, trade.total_amount.to_r * rate_lookup.exchange_rate.rate.to_r ]
        end
        calculation = Position::Calculator.for(trades:, amount_for: reporting_amounts.method(:fetch))
        cash_flows = reporting_amounts.map do |trade, amount|
          amounts_by_side = { "buy" => amount, "sell" => -amount }
          CashFlow.new(traded_on: trade.traded_on, amount: amounts_by_side.fetch(trade.side))
        end
        Replay.new(
          calculation:, net_cash_flow: cash_flows.sum(&:amount),
          invested_amount: reporting_amounts.sum { |trade, amount| trade.buy? ? amount : 0 }, cash_flows:
        )
      end

      def exchange_rate_for(base_currency, rate_date)
        @exchange_rate_lookups[[ base_currency, rate_date ]] ||= exchange_rate_service.read(
          base_currency:, quote_currency: reporting_currency, rate_date:
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
          net_cash_flow_amount: decimal(state.net_cash_flow), invested_amount: decimal(state.invested_amount), status: :available,
          daily_closing_price:, exchange_rate_lookup:, cash_flows: state.cash_flows
        )
      end

      def closed_result(state)
        zero = BigDecimal("0")
        PositionResult.new(
          instrument:, quantity: zero, reporting_cost_basis_amount: zero, market_value_amount: zero,
          realized_gain_amount: decimal(state.calculation.realized_gain_amount), unrealized_gain_amount: zero,
          net_cash_flow_amount: decimal(state.net_cash_flow), invested_amount: decimal(state.invested_amount), status: :closed,
          daily_closing_price: nil, exchange_rate_lookup: nil, cash_flows: state.cash_flows
        )
      end

      def missing_result(daily_closing_price: nil, exchange_rate_lookup: nil)
        PositionResult.new(
          instrument:, quantity: nil, reporting_cost_basis_amount: nil, market_value_amount: nil,
          realized_gain_amount: nil, unrealized_gain_amount: nil, net_cash_flow_amount: nil,
          invested_amount: nil,
          status: :missing, daily_closing_price:, exchange_rate_lookup:, cash_flows: []
        )
      end

      def decimal(value)
        BigDecimal(value, Position::ANALYTICAL_DECIMAL_PRECISION)
      end
    end
  end
end
