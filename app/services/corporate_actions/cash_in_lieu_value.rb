module CorporateActions
  class CashInLieuValue
    Result = Data.define(:amount, :currency, :status, :exchange_rate_lookup) do
      def available? = status == :available
      def missing? = status == :missing
    end

    def self.for(corporate_action:, reporting_currency:, exchange_rates: HistoricalExchangeRate::Service.new)
      new(corporate_action:, reporting_currency:, exchange_rates:).calculate
    end

    def initialize(corporate_action:, reporting_currency:, exchange_rates:)
      @corporate_action = corporate_action
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
      @exchange_rates = exchange_rates
    end

    def calculate
      lookup = exchange_rates.read(
        base_currency: corporate_action.currency,
        quote_currency: reporting_currency,
        rate_date: corporate_action.effective_on
      )
      return missing(lookup) unless lookup.available?

      amount = corporate_action.cash_in_lieu_amount.to_d.to_r * lookup.exchange_rate.rate.to_r
      Result.new(amount:, currency: reporting_currency, status: :available, exchange_rate_lookup: lookup)
    end

    private

    attr_reader :corporate_action, :reporting_currency, :exchange_rates

    def missing(exchange_rate_lookup)
      Result.new(amount: nil, currency: reporting_currency, status: :missing, exchange_rate_lookup:)
    end
  end
end
