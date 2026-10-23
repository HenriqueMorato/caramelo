class HistoricalExchangeRate
  class PerformanceTargets
    def initialize(base_currency:, quote_currency:)
      @base_currency = base_currency
      @quote_currency = quote_currency
    end

    def users
      @users ||= User.where(id: affected_user_ids).to_a
    end

    def instrument_targets
      @instrument_targets ||= users.flat_map do |user|
        targets_for_user(user)
      end
    end

    private

    attr_reader :base_currency, :quote_currency

    def affected_user_ids
      currencies = [ base_currency, quote_currency ]
      trade_user_ids = Trade.where(currency: currencies)
        .or(Trade.where(settlement_currency: currencies)).distinct.pluck(:user_id)
      income_user_ids = CorporateAction.effective_on_or_before(Date.current).joins(:instrument)
        .where(
          "corporate_actions.currency IN (:currencies) OR instruments.currency IN (:currencies)",
          currencies: currencies
        ).distinct.pluck(:user_id)
      trade_user_ids | income_user_ids
    end

    def targets_for_user(user)
      trades = user.trades.includes(:instrument).to_a
      income = user.corporate_actions.effective_on_or_before(Date.current).includes(:instrument).to_a
      instruments = (trades.map(&:instrument) + income.map(&:instrument)).uniq
      trades_by_instrument = trades.group_by(&:instrument_id)
      income_by_instrument = income.group_by(&:instrument_id)
      instruments.flat_map do |instrument|
        targets_for_instrument(
          user:, instrument:, trades: trades_by_instrument.fetch(instrument.id, []),
          income: income_by_instrument.fetch(instrument.id, [])
        )
      end
    end

    def targets_for_instrument(user:, instrument:, trades:, income:)
      dependencies = [
        instrument.currency,
        *trades.filter_map(&:settlement_currency),
        *income.filter_map(&:currency)
      ].uniq
      instrument_target_currencies(user:, instrument:).filter_map do |reporting_currency|
        next unless dependencies.any? { |dependency| affected_pair?(dependency, reporting_currency) }

        [ user, instrument, reporting_currency ]
      end
    end

    def instrument_target_currencies(user:, instrument:)
      materialized = user.instrument_performance_materializations.where(instrument:).pluck(:reporting_currency)
      materialized | [ instrument.currency, user.reporting_currency ]
    end

    def affected_pair?(instrument_currency, reporting_currency)
      instrument_currency != reporting_currency &&
        [ instrument_currency, reporting_currency ].sort == [ base_currency, quote_currency ].sort
    end
  end
end
