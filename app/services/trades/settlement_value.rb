module Trades
  class SettlementValue
    # Exact positive trade amount expressed in the requested reporting currency.
    # `exchange_rate_lookup` is present only when historical FX was required.
    Result = Data.define(:amount, :currency, :status, :exchange_rate_lookup) do
      def available? = status == :available
      def missing? = status == :missing
    end

    def self.for(trade:, reporting_currency:, exchange_rates: HistoricalExchangeRate::Service.new)
      new(trade:, reporting_currency:, exchange_rates:).calculate
    end

    def initialize(trade:, reporting_currency:, exchange_rates:)
      @trade = trade
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
      @exchange_rates = exchange_rates
    end

    def calculate
      return available(trade.total_amount.to_r) if trade.currency == reporting_currency
      return explicit_conversion if trade.explicit_settlement_conversion?

      historical_conversion(trade.total_amount.to_r, from: trade.currency)
    end

    private

    attr_reader :trade, :reporting_currency, :exchange_rates

    def explicit_conversion
      settlement_amount = trade.total_amount.to_r * trade.settlement_exchange_rate.to_r
      return available(settlement_amount) if trade.settlement_currency == reporting_currency

      historical_conversion(settlement_amount, from: trade.settlement_currency)
    end

    def historical_conversion(amount, from:)
      lookup = exchange_rates.read(
        base_currency: from, quote_currency: reporting_currency, rate_date: trade.traded_on
      )
      return missing(lookup) unless lookup.available?

      available(amount * lookup.exchange_rate.rate.to_r, exchange_rate_lookup: lookup)
    end

    def available(amount, exchange_rate_lookup: nil)
      Result.new(amount:, currency: reporting_currency, status: :available, exchange_rate_lookup:)
    end

    def missing(exchange_rate_lookup)
      Result.new(amount: nil, currency: reporting_currency, status: :missing, exchange_rate_lookup:)
    end
  end
end
