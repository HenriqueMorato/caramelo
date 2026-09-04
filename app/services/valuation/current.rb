module Valuation
  class Current
    Result = Data.define(:market_value, :status, :exchange_rate_lookup) do
      def available? = market_value.present?
      def stale? = status == :stale
      def missing? = status == :missing
      def same_currency? = status == :same_currency
    end

    def self.for(position:, market_price:, exchange_rate_service: ExchangeRate::Service.default,
      reporting_currency: User.owner.reporting_currency)
      new(position:, market_price:, exchange_rate_service:, reporting_currency:).calculate
    end

    def initialize(position:, market_price:, exchange_rate_service:, reporting_currency:)
      @position = position
      @market_price = market_price
      @exchange_rate_service = exchange_rate_service
      @reporting_currency = reporting_currency
    end

    def calculate
      return missing_result unless position && market_price.current_market_price

      quote = market_price.current_market_price
      native_amount = quote.valuation_amount_for(position.quantity)
      if quote.currency == reporting_currency
        return Result.new(
          market_value: Money.from_amount(native_amount, reporting_currency),
          status: market_price.stale? ? :stale : :same_currency,
          exchange_rate_lookup: nil
        )
      end

      rate_lookup = exchange_rate_service.read(base_currency: quote.currency, quote_currency: reporting_currency)
      return missing_result(rate_lookup) unless rate_lookup.exchange_rate

      Result.new(
        market_value: Money.from_amount(native_amount * rate_lookup.exchange_rate.rate, reporting_currency),
        status: market_price.stale? || rate_lookup.stale? ? :stale : :current,
        exchange_rate_lookup: rate_lookup
      )
    end

    private

    attr_reader :position, :market_price, :exchange_rate_service, :reporting_currency

    def missing_result(exchange_rate_lookup = nil)
      Result.new(market_value: nil, status: :missing, exchange_rate_lookup:)
    end
  end
end
