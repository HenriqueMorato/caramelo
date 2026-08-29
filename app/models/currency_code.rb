class CurrencyCode
  ISO_CODE = /\A[A-Z]{3}\z/

  def self.normalize(value)
    code = value.to_s.strip.upcase
    raise ArgumentError, "currency is invalid" unless code.match?(ISO_CODE) && Money::Currency.find(code)

    code
  end
end
