class IsoCurrencyValidator < ActiveModel::EachValidator
  ISO_CODE = /\A[A-Z]{3}\z/
  ISO_NUMERIC = /\A\d{3}\z/

  def validate_each(record, attribute, value)
    currency = Money::Currency.find(value) if value.is_a?(String) && value.match?(ISO_CODE)
    return if currency&.iso_numeric&.match?(ISO_NUMERIC)

    record.errors.add(attribute, :invalid)
  end
end
