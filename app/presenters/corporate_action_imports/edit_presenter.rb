module CorporateActionImports
  class EditPresenter
    CASH_KINDS = %w[dividend jcp].freeze
    QUANTITY_KINDS = %w[split reverse_split share_bonus].freeze

    attr_reader :import, :institutions

    def initialize(import:, institutions:)
      @import = import
      @institutions = institutions
    end

    def conflict?
      import.conflict?
    end

    def provider_kind
      provider_candidate["kind"].presence
    end

    def provider_event_on
      provider_candidate["event_on"].presence
    end

    def provider_ratio
      [ provider_candidate["ratio_numerator"], provider_candidate["ratio_denominator"] ].compact.join(":").presence
    end

    def provider_amount_per_share
      provider_candidate["amount_per_share"].presence
    end

    def provider_payload
      import.raw_payload_hash
    end

    def current_kind
      import.kind
    end

    def current_event_on
      import.event_on
    end

    def institution
      import.institution
    end

    def institution_id
      import.institution_id
    end

    def review_kind
      return import.kind unless conflict?

      provider_kind || import.kind
    end

    def review_event_on
      return import.event_on unless conflict?

      provider_event_on || import.event_on
    end

    def review_ratio_numerator
      return import.ratio_numerator unless conflict?

      provider_candidate["ratio_numerator"].presence || import.ratio_numerator
    end

    def review_ratio_denominator
      return import.ratio_denominator unless conflict?

      provider_candidate["ratio_denominator"].presence || import.ratio_denominator
    end

    def review_ex_date
      return import.ex_date unless conflict?

      provider_event_on || import.ex_date
    end

    def cash_action?
      review_kind.to_s.in?(CASH_KINDS)
    end

    def institution_select?
      institutions.size > 1 || import.warning_list.include?("multiple_institutions")
    end

    def hidden_institution?
      !institution_select? && import.institution.present?
    end

    def kind_options
      options = if cash_action?
        CASH_KINDS.dup
      elsif review_kind.to_s.in?(QUANTITY_KINDS)
        QUANTITY_KINDS.dup
      else
        CorporateActionImport.kinds.keys
      end
      options -= [ "jcp" ] unless import.instrument&.currency_brl?
      options
    end

    def review_currency
      import.review_currency
    end

    def currency_subunit
      @currency_subunit ||= if review_currency
        Money::Currency.find(review_currency).subunit_to_unit
      else
        100
      end
    end

    def suggested_payment_date
      import.suggested_payment_date
    end

    def payment_date_suggested?
      import.paid_on.blank? && suggested_payment_date.present?
    end

    def estimated_gross_amount_cents
      import.estimated_gross_amount_cents
    end

    def gross_amount_value
      amount_cents = import.gross_amount_cents || estimated_gross_amount_cents
      return unless amount_cents

      (amount_cents.to_d / currency_subunit).to_s("F")
    end

    def withholding_tax_value
      return unless import.withholding_tax_cents

      import.withholding_tax_cents.to_d / currency_subunit
    end

    private

    def provider_candidate
      @provider_candidate ||= import.normalized_candidate
    end
  end
end
