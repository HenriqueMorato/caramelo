module CorporateActionImports
  class Review
    Result = Data.define(:import, :success?, :error)

    def self.call(import:, attributes: {})
      new(import:, attributes:).call
    end

    def initialize(import:, attributes: {})
      @import = import
      @attributes = attributes.to_h.symbolize_keys
    end

    def call
      import.with_lock do
        return Result.new(import, false, "Confirmed imports cannot be edited.") if import.confirmed?

        assign_attributes
        import.status = :pending
        import.failure_message = nil
        import.reviewed_at = nil
        import.save!
      end
      Result.new(import, true, nil)
    rescue ActiveRecord::RecordInvalid, ArgumentError, TypeError => error
      Result.new(import, false, error_message(error))
    end

    private

    attr_reader :import, :attributes

    def assign_attributes
      kind = attributes[:kind].presence || import.kind
      raise ArgumentError, "event type is required" if kind.blank?

      kind = "split" if kind.to_s == "stock_split"
      import.kind = kind
      if kind.to_s.in?(%w[dividend jcp])
        import.paid_on = date_value(:paid_on, import.paid_on)
        import.ex_date = date_value(:ex_date, import.ex_date)
        import.gross_amount_cents = amount_cents(:gross_amount, :gross_amount_cents, import.gross_amount_cents)
        import.withholding_tax_cents = amount_cents(
          :withholding_tax, :withholding_tax_cents, import.withholding_tax_cents || 0
        )
        import.net_amount_cents = import.gross_amount_cents &&
          import.gross_amount_cents - import.withholding_tax_cents
      else
        import.event_on = date_value(:effective_on, import.event_on)
        import.ratio_numerator = integer_value(:ratio_numerator, import.ratio_numerator)
        import.ratio_denominator = integer_value(:ratio_denominator, import.ratio_denominator)
        import.paid_on = nil
        import.ex_date = nil
        import.gross_amount_cents = nil
        import.withholding_tax_cents = nil
        import.net_amount_cents = nil
      end
    end

    def date_value(key, fallback)
      value = attributes.key?(key) ? attributes[key] : fallback
      return value if value.is_a?(Date)
      return if value.blank?

      Date.iso8601(value.to_s)
    end

    def integer_value(key, fallback)
      value = attributes.key?(key) ? attributes[key] : fallback
      return if value.blank?

      Integer(value)
    end

    def amount_cents(amount_key, cents_key, fallback)
      value = if attributes.key?(cents_key)
        attributes[cents_key]
      elsif attributes.key?(amount_key)
        amount = BigDecimal(attributes[amount_key].to_s)
        currency = import.currency || import.instrument&.currency
        raise ArgumentError, "currency is required" if currency.blank?

        subunit = Money::Currency.find(currency).subunit_to_unit
        (amount * subunit).round(0).to_i
      else
        fallback
      end
      return if value.blank?

      Integer(value)
    end

    def error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record) && error.record

      error.message
    end
  end
end
