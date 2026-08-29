module Valuation
  class Historical
    Result = Data.define(
      :valuation_date, :native_market_value_amount, :market_value_amount,
      :market_value, :status, :daily_closing_price, :exchange_rate_lookup
    ) do
      def available? = market_value.present?
      def missing? = status == :missing
      def closed? = status == :closed
      def same_currency? = status == :same_currency
    end

    def self.for(position:, valuation_date:, exchange_rate_service: HistoricalExchangeRate::Service.new,
      daily_closing_price_provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier,
      reporting_currency: Rails.configuration.x.local_folio.reporting_currency)
      new(
        position:, valuation_date:, exchange_rate_service:, daily_closing_price_provider:,
        reporting_currency:
      ).calculate
    end

    def initialize(position:, valuation_date:, exchange_rate_service:, daily_closing_price_provider:, reporting_currency:)
      @position = position
      @valuation_date = valuation_date
      @exchange_rate_service = exchange_rate_service
      @daily_closing_price_provider = daily_closing_price_provider
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
    end

    def calculate
      validate_valuation_date!
      return closed_result if position.closed?

      daily_closing_price = find_daily_closing_price
      return missing_result(daily_closing_price:) unless daily_closing_price

      native_market_value_amount = position.quantity * daily_closing_price.close_price
      rate_lookup = exchange_rate_service.read(
        base_currency: daily_closing_price.currency,
        quote_currency: reporting_currency,
        rate_date: valuation_date
      )
      return missing_result(daily_closing_price:, exchange_rate_lookup: rate_lookup) unless rate_lookup.available?

      market_value_amount = native_market_value_amount * rate_lookup.exchange_rate.rate
      Result.new(
        valuation_date:, native_market_value_amount:, market_value_amount:,
        market_value: Money.from_amount(market_value_amount, reporting_currency),
        status: rate_lookup.same_currency? ? :same_currency : :available,
        daily_closing_price:, exchange_rate_lookup: rate_lookup
      )
    end

    private

    attr_reader :position, :valuation_date, :exchange_rate_service, :daily_closing_price_provider, :reporting_currency

    def find_daily_closing_price
      DailyClosingPrice.find_by(
        instrument: position.instrument, trading_date: valuation_date,
        provider: daily_closing_price_provider
      )
    end

    def closed_result
      Result.new(
        valuation_date:, native_market_value_amount: BigDecimal("0"), market_value_amount: BigDecimal("0"),
        market_value: Money.new(0, reporting_currency), status: :closed,
        daily_closing_price: nil, exchange_rate_lookup: nil
      )
    end

    def missing_result(daily_closing_price:, exchange_rate_lookup: nil)
      Result.new(
        valuation_date:, native_market_value_amount: nil, market_value_amount: nil,
        market_value: nil, status: :missing, daily_closing_price:, exchange_rate_lookup:
      )
    end

    def validate_valuation_date!
      return if valuation_date.is_a?(Date) && valuation_date <= Date.current

      raise ArgumentError, "valuation date must be on or before today"
    end
  end
end
