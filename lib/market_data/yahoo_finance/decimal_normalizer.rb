module MarketData
  module YahooFinance
    module DecimalNormalizer
      module_function

      def positive(value:, float_message:, invalid_message:, nonpositive_message:)
        raise InvalidResponse, float_message if value.is_a?(Float)

        decimal = BigDecimal(value.to_s)
        raise InvalidResponse, nonpositive_message unless decimal.finite? && decimal.positive?

        decimal
      rescue ArgumentError
        raise InvalidResponse, invalid_message
      end
    end
  end
end
