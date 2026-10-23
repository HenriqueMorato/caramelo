module Performance
  class Portfolio
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
        calculation = state.calculation
        quantity = calculation.quantity
        return closed_result(state) if quantity.zero?

        daily_closing_price = find_daily_closing_price
        return missing_result(daily_closing_price:) unless daily_closing_price

        exchange_rate_lookup = exchange_rates.read(
          base_currency: daily_closing_price.currency,
          quote_currency: reporting_currency,
          rate_date: valuation_date
        )
        return missing_result(daily_closing_price:, exchange_rate_lookup:) unless exchange_rate_lookup.available?

        market_value = quantity * daily_closing_price.close_price.to_r *
          exchange_rate_lookup.exchange_rate.rate.to_r
        available_result(state, market_value, daily_closing_price:, exchange_rate_lookup:)
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
        reporting_amounts = reporting_amounts_for_trades
        return unless reporting_amounts

        quantity_actions = corporate_actions.select(&:quantity_action?)
        cash_in_lieu_amounts = cash_in_lieu_amounts_for(quantity_actions)
        return unless cash_in_lieu_amounts

        calculation = Position::Calculator.for(
          trades:, amount_for: reporting_amounts.method(:fetch), corporate_actions: quantity_actions,
          cash_in_lieu_amount_for: cash_in_lieu_amounts.method(:fetch)
        )
        income_amounts = income_amounts_for_cash_actions
        return unless income_amounts

        Replay.new(
          calculation:, net_cash_flow: trade_cash_flow_amount(reporting_amounts) - cash_in_lieu_amounts.sum(&:last),
          investment_income: income_amounts.sum(&:last),
          invested_amount: reporting_amounts.sum { |trade, amount| trade.buy? ? amount : 0 },
          cash_flows: cash_flows_for(reporting_amounts, income_amounts, cash_in_lieu_amounts)
        )
      end

      def reporting_amounts_for_trades
        trades.to_h do |trade|
          settlement = Trades::SettlementValue.for(
            trade:, reporting_currency:, exchange_rates:
          )
          return unless settlement.available?

          [ trade, settlement.amount ]
        end
      end

      def cash_in_lieu_amounts_for(quantity_actions)
        quantity_actions.select(&:cash_in_lieu?).to_h do |action|
          proceeds = CorporateActions::CashInLieuValue.for(
            corporate_action: action, reporting_currency:, exchange_rates:
          )
          return unless proceeds.available?

          [ action, proceeds.amount ]
        end
      end

      def income_amounts_for_cash_actions
        corporate_actions.select(&:cash_action?).to_h do |action|
          distribution = CorporateActions::CashDistributionValue.for(
            corporate_action: action, reporting_currency:, exchange_rates:
          )
          return unless distribution.available?

          [ action, distribution.amount ]
        end
      end

      def trade_cash_flow_amount(reporting_amounts)
        reporting_amounts.sum do |trade, amount|
          trade.buy? ? amount : -amount
        end
      end

      def cash_flows_for(reporting_amounts, income_amounts, cash_in_lieu_amounts)
        trade_cash_flows = reporting_amounts.map do |trade, amount|
          Portfolio::CashFlow.new(
            occurred_on: trade.traded_on,
            amount: trade.buy? ? amount : -amount,
            source: :trade
          )
        end
        income_cash_flows = income_amounts.map do |action, amount|
          Portfolio::CashFlow.new(occurred_on: action.performance_on, amount: -amount, source: :corporate_action)
        end
        cash_in_lieu_flows = cash_in_lieu_amounts.map do |action, amount|
          Portfolio::CashFlow.new(occurred_on: action.effective_on, amount: -amount, source: :cash_in_lieu)
        end

        trade_cash_flows + income_cash_flows + cash_in_lieu_flows
      end

      def find_daily_closing_price
        DailyClosingPrice.where(instrument:, provider: daily_closing_price_provider)
          .where(trading_date: MarketData::HistoricalObservationWindow.for(valuation_date))
          .order(trading_date: :desc)
          .first
      end

      def available_result(state, market_value, daily_closing_price:, exchange_rate_lookup:)
        calculation = state.calculation
        investment_income = decimal(state.investment_income)
        cost_basis_amount = calculation.cost_basis_amount
        reporting_cost_basis = decimal(cost_basis_amount)
        market_value_amount = decimal(market_value)
        Portfolio::PositionResult.new(
          instrument:, quantity: decimal(calculation.quantity), reporting_cost_basis_amount: reporting_cost_basis,
          market_value_amount:, realized_gain_amount: decimal(calculation.realized_gain_amount),
          unrealized_gain_amount: decimal(market_value - cost_basis_amount),
          net_cash_flow_amount: decimal(state.net_cash_flow),
          investment_income_amount: investment_income,
          investment_income: Money.from_amount(investment_income, reporting_currency),
          invested_amount: decimal(state.invested_amount), status: :available,
          daily_closing_price:, exchange_rate_lookup:, cash_flows: state.cash_flows
        )
      end

      def closed_result(state)
        zero = BigDecimal("0")
        investment_income = decimal(state.investment_income)
        Portfolio::PositionResult.new(
          instrument:, quantity: zero, reporting_cost_basis_amount: zero, market_value_amount: zero,
          realized_gain_amount: decimal(state.calculation.realized_gain_amount), unrealized_gain_amount: zero,
          net_cash_flow_amount: decimal(state.net_cash_flow),
          investment_income_amount: investment_income,
          investment_income: Money.from_amount(investment_income, reporting_currency),
          invested_amount: decimal(state.invested_amount), status: :closed,
          daily_closing_price: nil, exchange_rate_lookup: nil, cash_flows: state.cash_flows
        )
      end

      def missing_result(daily_closing_price: nil, exchange_rate_lookup: nil)
        Portfolio::PositionResult.new(
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
