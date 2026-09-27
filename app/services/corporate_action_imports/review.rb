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
        return Result.new(import, false, "Review the provider update before saving.") if provider_update_requires_acknowledgement?

        assign_attributes
        import.status = ambiguous_institution? ? :ambiguous : :pending
        import.failure_message = nil
        import.reviewed_at = Time.current
        import.save!
      end
      Result.new(import, true, nil)
    rescue ActiveRecord::RecordInvalid, ArgumentError, TypeError, FloatDomainError => error
      Result.new(import, false, error_message(error))
    end

    private

    attr_reader :import, :attributes

    def provider_update_requires_acknowledgement?
      import.conflict? && !ActiveModel::Type::Boolean.new.cast(attributes[:accept_provider_update])
    end

    def assign_attributes
      kind = attributes[:kind].presence || import.kind
      raise ArgumentError, "event type is required" if kind.blank?

      kind = "split" if CorporateActionImport.stock_split_kind?(kind)
      import.kind = kind
      assign_institution if attributes.key?(:institution_id)
      if import.cash_action?
        import.paid_on = date_value(:paid_on, import.paid_on)
        import.ex_date = date_value(:ex_date, import.ex_date)
        import.gross_amount_cents = amount_cents(:gross_amount, :gross_amount_cents, import.gross_amount_cents)
        import.withholding_tax_cents = amount_cents(
          :withholding_tax, :withholding_tax_cents, import.withholding_tax_cents || 0, blank_fallback: true
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

    def assign_institution
      institution_id = attributes[:institution_id].presence
      return import.institution = nil if institution_id.blank?

      import.institution = import.user.institutions.find_by(id: institution_id)
      raise ArgumentError, "institution is not available for this owner" unless import.institution
    end

    def ambiguous_institution?
      import.institution.blank? && import.warning_list.include?("multiple_institutions")
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

    def amount_cents(amount_key, cents_key, fallback, blank_fallback: false)
      value = if attributes.key?(cents_key)
        attributes[cents_key].presence || (blank_fallback ? fallback : nil)
      elsif attributes.key?(amount_key)
        raw_amount = attributes[amount_key]
        if raw_amount.blank?
          blank_fallback ? fallback : nil
        else
          amount = decimal_value(raw_amount)
          currency = import.currency || import.instrument&.currency
          raise ArgumentError, "currency is required" if currency.blank?

          subunit = Money::Currency.find(currency).subunit_to_unit
          (amount * subunit).round(0).to_i
        end
      else
        fallback
      end
      return if value.blank?

      Integer(value)
    end

    def decimal_value(value)
      decimal = BigDecimal(value.to_s)
      raise ArgumentError, "amount is invalid" unless decimal.finite?

      decimal
    end

    def error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record) && error.record

      error.message
    end
  end
end
