module CorporateActionImports
  class Scan
    Result = Data.define(:from, :to, :source, :imports, :errors, :created_count) do
      def reviewable_count = imports.count(&:reviewable?)
      def error_count = errors.size
    end

    def self.call(user:, from:, to:, source: "yahoo_finance", instrument: nil, provider: nil, strict: false)
      new(user:, from:, to:, source:, instrument:, provider:, strict:).call
    end

    def initialize(user:, from:, to:, source:, instrument:, provider:, strict:)
      @user = user
      @from = from
      @to = to
      @source = source.to_s.strip.downcase
      @instrument = instrument
      @provider = provider || default_provider
      @strict = strict
    end

    def call
      validate_range!
      imports = []
      errors = []
      created_count = 0
      instruments.each do |current_instrument|
        begin
          @provider.fetch(instrument: current_instrument, from:, to:).each do |candidate|
            import, created = persist_candidate(current_instrument, candidate)
            imports << import
            created_count += 1 if created
          end
        rescue StandardError => error
          raise if strict

          errors << { instrument: current_instrument, error: error }
        end
      end
      Result.new(from:, to:, source:, imports:, errors:, created_count:)
    end

    private

    attr_reader :user, :from, :to, :source, :instrument, :provider

    def strict = @strict

    def instruments
      return [ instrument ] if instrument

      instrument_ids = user.trades.where(traded_on: ..to).distinct.pluck(:instrument_id)
      Instrument.where(id: instrument_ids).alphabetical.to_a
    end

    def persist_candidate(current_instrument, candidate)
      source_reference = candidate.source_reference.to_s
      raise ArgumentError, "provider event reference is blank" if source_reference.empty?

      import = user.corporate_action_imports.find_or_initialize_by(
        source:, source_reference:
      )
      was_new = import.new_record?
      previous_status = import.status
      changed_after_confirmation = import.confirmed? && candidate_changed?(import, current_instrument, candidate)
      preserve_review = import.confirmed? || import.ignored?
      assign_candidate(import, current_instrument, candidate, preserve_review:)
      if changed_after_confirmation
        import.status = :conflict
        import.failure_message = "The provider payload changed after confirmation; review it explicitly."
      elsif previous_status == "confirmed" || previous_status == "ignored"
        import.status = previous_status
      else
        import.status = :pending
        import.failure_message = nil
      end
      import.reviewed_at = nil unless import.confirmed? || import.ignored?
      import.save!
      [ import, was_new ]
    end

    def assign_candidate(import, current_instrument, candidate, preserve_review: false)
      institution, institution_warning = institution_match_for(current_instrument)
      import.instrument = current_instrument
      import.institution = institution
      import.source = source
      import.provider_symbol = candidate.provider_symbol
      import.provider_exchange = candidate.provider_exchange
      import.kind = candidate.kind
      import.event_on = candidate.event_on
      import.ex_date = candidate.kind.to_s.in?(%w[dividend jcp]) ? candidate.event_on : nil
      import.paid_on = nil unless preserve_review
      import.amount_per_share = candidate.amount_per_share&.to_s("F")
      unless preserve_review
        import.gross_amount_cents = nil
        import.withholding_tax_cents = nil
        import.net_amount_cents = nil
      end
      import.currency = candidate.currency
      import.ratio_numerator = candidate.ratio_numerator
      import.ratio_denominator = candidate.ratio_denominator
      import.normalized_candidate = normalized_candidate(candidate)
      import.raw_payload_hash = candidate.raw_payload
      import.warning_list = candidate.warnings + [ institution_warning ].compact
    end

    def normalized_candidate(candidate)
      {
        "kind" => candidate.kind.to_s,
        "event_on" => candidate.event_on&.iso8601,
        "amount_per_share" => candidate.amount_per_share&.to_s("F"),
        "ratio_numerator" => candidate.ratio_numerator,
        "ratio_denominator" => candidate.ratio_denominator,
        "currency" => candidate.currency,
        "provider_symbol" => candidate.provider_symbol,
        "provider_exchange" => candidate.provider_exchange
      }
    end

    def candidate_changed?(import, current_instrument, candidate)
      import.instrument_id != current_instrument.id ||
        import.normalized_candidate != normalized_candidate(candidate) ||
        canonical_json(import.raw_payload_hash) != canonical_json(candidate.raw_payload)
    end

    def institution_match_for(current_instrument)
      ids = user.trades.where(instrument: current_instrument).where.not(institution_id: nil)
        .distinct.pluck(:institution_id)
      return [ nil, "multiple_institutions" ] if ids.length > 1
      return [ nil, nil ] if ids.empty?

      [ user.institutions.find_by(id: ids.first), nil ]
    end

    def canonical_json(value)
      JSON.generate(value)
    end

    def default_provider
      Providers::YahooFinance.new
    end

    def validate_range!
      raise ArgumentError, "unsupported import source" unless source == "yahoo_finance"

      unless from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current
        raise ArgumentError, "import range must use past dates in chronological order"
      end
    end
  end
end
