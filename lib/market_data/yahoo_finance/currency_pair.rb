module MarketData
  module YahooFinance
    class CurrencyPair
      ISO_CODE = /\A[A-Z]{3}\z/

      attr_reader :base_currency, :quote_currency

      def initialize(base_currency:, quote_currency:)
        @base_currency = self.class.normalize(base_currency)
        @quote_currency = self.class.normalize(quote_currency)
        raise ArgumentError, "currencies must differ" if @base_currency == @quote_currency
      end

      def symbol
        "#{base_currency}#{quote_currency}=X"
      end

      def self.normalize(currency)
        normalized = currency.to_s.strip.upcase
        raise ArgumentError, "currency is invalid" unless normalized.match?(ISO_CODE) && Money::Currency.find(normalized)

        normalized
      end
    end
  end
end
