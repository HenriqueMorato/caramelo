module CorporateActionImports
  class Confirmation
    Result = Data.define(:status, :import, :corporate_action, :error) do
      def confirmed? = status == :confirmed
      def duplicate? = status == :duplicate
      def ambiguous? = status == :ambiguous
      def skipped? = %i[ignored conflict ambiguous].include?(status)
      def failed? = status == :failed
    end

    def self.call(import:, attributes: {})
      new(import:, attributes:).call
    end

    def initialize(import:, attributes: {})
      @import = import
      @attributes = attributes.to_h.symbolize_keys
    end

    def call
      import.with_lock do
        import.reload
        import.association(:corporate_action).reset
        if import.confirmed? && import.corporate_action_id.blank?
          import.update!(status: :pending, reviewed_at: nil, failure_message: nil)
        end
        return result(:duplicate, corporate_action: import.corporate_action) if import.confirmed?
        return result(:ignored) if import.ignored?
        return result(:conflict, error: import.failure_message) if import.conflict?
        if import.ambiguous? && import.institution.blank?
          return result(:ambiguous, error: "An institution must be selected before confirmation.")
        end

        action = nil
        CorporateAction.transaction do
          action = build_action
          action.save!
          import.update!(
            status: :confirmed, corporate_action: action, reviewed_at: Time.current,
            failure_message: nil
          )
        end
        result(:confirmed, corporate_action: action)
      end
    rescue ActiveRecord::RecordNotUnique => error
      handle_duplicate(error)
    rescue ActiveRecord::RecordInvalid => error
      duplicate = existing_action
      return link_duplicate!(duplicate) if duplicate && import.corporate_action_id.blank? && !import.conflict?

      mark_failed!(error.record.errors.full_messages.to_sentence)
      result(:failed, error: error.record.errors.full_messages.to_sentence)
    rescue ArgumentError, TypeError, FloatDomainError => error
      mark_failed!(error.message)
      result(:failed, error: error.message)
    end

    private

    attr_reader :import, :attributes

    def build_action
      action = import.corporate_action if import.corporate_action_id.present?
      action ||= CorporateAction.new
      action.assign_attributes(
        user: import.user, instrument: import.instrument, institution: import.institution,
        kind: corporate_action_kind, status: :confirmed,
        source: import.source, source_reference: import.source_reference,
        raw_payload: import.raw_payload
      )
      if action.cash_action?
        assign_cash_fields(action)
      else
        assign_quantity_fields(action)
      end
      action
    end

    def corporate_action_kind
      kind = attributes.fetch(:kind, import.kind).to_s
      return :stock_split if CorporateActionImport.stock_split_kind?(kind)

      kind
    end

    def assign_cash_fields(action)
      action.paid_on = date_value(:paid_on, import.paid_on)
      action.ex_date = date_value(:ex_date, import.ex_date)
      action.currency = import.currency || import.instrument&.currency
      action.gross_amount_cents = cents_value(:gross_amount_cents, :gross_amount, import.gross_amount_cents, action.currency)
      action.withholding_tax_cents = cents_value(
        :withholding_tax_cents, :withholding_tax, import.withholding_tax_cents || 0, action.currency
      )
      action.net_amount_cents = action.gross_amount_cents &&
        action.gross_amount_cents - action.withholding_tax_cents
    end

    def assign_quantity_fields(action)
      action.effective_on = date_value(:effective_on, import.event_on)
      action.ratio_numerator = integer_value(:ratio_numerator, import.ratio_numerator)
      action.ratio_denominator = integer_value(:ratio_denominator, import.ratio_denominator)
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

    def cents_value(cents_key, amount_key, fallback, currency)
      value = if attributes.key?(cents_key)
        attributes[cents_key].presence || fallback
      elsif attributes.key?(amount_key)
        attributes[amount_key].blank? ? fallback : amount_to_cents(attributes[amount_key], currency)
      else
        fallback
      end
      return if value.blank?

      Integer(value)
    end

    def amount_to_cents(value, currency)
      raise ArgumentError, "currency is required" if currency.blank?

      decimal = BigDecimal(value.to_s)
      raise ArgumentError, "amount is invalid" unless decimal.finite?

      subunit = Money::Currency.find(currency).subunit_to_unit
      (decimal * subunit).round(0).to_i
    end

    def handle_duplicate(error)
      duplicate = CorporateAction.find_by(
        user: import.user, source: import.source, source_reference: import.source_reference
      )
      return link_duplicate!(duplicate) if duplicate

      mark_failed!(error.message)
      result(:failed, error: error.message)
    end

    def mark_failed!(message)
      import.update_columns(status: "failed", failure_message: message.to_s, reviewed_at: Time.current)
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def existing_action
      CorporateAction.find_by(
        user: import.user, source: import.source, source_reference: import.source_reference
      )
    end

    def link_duplicate!(duplicate)
      import.update_columns(
        status: "confirmed", corporate_action_id: duplicate.id,
        reviewed_at: Time.current, failure_message: nil
      )
      result(:duplicate, corporate_action: duplicate)
    end

    def result(status, corporate_action: nil, error: nil)
      Result.new(status, import, corporate_action, error)
    end
  end
end
