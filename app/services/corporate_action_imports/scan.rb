module CorporateActionImports
  class Scan
    class Superseded < StandardError; end

    Result = Data.define(:from, :to, :source, :imports, :errors, :created_count) do
      def reviewable_count = imports.count(&:reviewable?)
      def error_count = errors.size
    end

    def self.call(user:, from:, to:, source: Providers::YAHOO_FINANCE, instrument: nil, provider: nil, strict: false,
      fence: nil)
      new(user:, from:, to:, source:, instrument:, provider:, strict:, fence:).call
    end

    def initialize(user:, from:, to:, source:, instrument:, provider:, strict:, fence: nil)
      @user = user
      @from = from
      @to = to
      @source = source.to_s.strip.downcase
      @instrument = instrument
      @provider = provider || default_provider
      @strict = strict
      @fence = fence
    end

    def call
      validate_range!
      result = scan_instruments
      Result.new(from:, to:, source:, **result)
    end

    private

    attr_reader :user, :from, :to, :source, :instrument, :provider, :fence

    def strict = @strict

    def scan_instruments
      imports = []
      errors = []
      created_count = 0
      instruments.each do |current_instrument|
        scan_instrument(current_instrument, imports, errors) { created_count += 1 }
      end
      { imports:, errors:, created_count: }
    end

    def scan_instrument(current_instrument, imports, errors)
      ensure_current_run!
      persist_candidates(current_instrument, imports) { yield }
    rescue Superseded
      raise
    rescue StandardError => error
      raise if strict

      errors << { instrument: current_instrument, error: error }
    end

    def fetch_candidates(current_instrument)
      fetch_from = [ from, trades_for(current_instrument).first.traded_on ].max
      @provider.fetch(instrument: current_instrument, from: fetch_from, to:)
    end

    def persist_candidates(current_instrument, imports)
      fetch_candidates(current_instrument).each do |candidate|
        next unless candidate_has_position?(current_instrument, candidate)

        import, created = persist_candidate_with_fence(current_instrument, candidate)
        imports << import
        yield if created
      end
    end

    def ensure_current_run!
      return unless fence
      return if fence.call { true }

      raise Superseded, "corporate-action scan generation was superseded"
    end

    def instruments
      return targeted_instrument if instrument

      traded_instruments
    end

    def targeted_instrument
      unless user.trades.where(instrument_id: instrument.id, traded_on: ..to).exists?
        raise ArgumentError, "instrument is not traded by this owner"
      end

      [ instrument ]
    end

    def traded_instruments
      instrument_ids = user.trades.where(traded_on: ..to).distinct.pluck(:instrument_id)
      Instrument.where(id: instrument_ids).alphabetical.to_a
    end

    def trades_for(current_instrument)
      @trades_by_instrument ||= {}
      instrument_id = current_instrument.id
      @trades_by_instrument.fetch(instrument_id) do
        @trades_by_instrument[instrument_id] = user.trades
          .where(instrument: current_instrument, traded_on: ..to)
          .order(:traded_on, :id).to_a
      end
    end

    def candidate_has_position?(current_instrument, candidate)
      event_on = candidate.event_on
      return true unless event_on

      quantity = 0.to_r
      quantity_timeline_for(current_instrument).each do |event_date, event_quantity|
        break if event_date > event_on

        quantity = event_quantity
      end
      quantity.positive?
    rescue Position::InvalidLongOnlyData, Position::InvalidQuantityActionData
      # Preserve the review item when existing ledger data cannot be replayed safely.
      true
    end

    def quantity_timeline_for(current_instrument)
      @quantity_timelines ||= {}
      instrument_id = current_instrument.id
      @quantity_timelines.fetch(instrument_id) do
        @quantity_timelines[instrument_id] = Position::Calculator.quantity_timeline(
          trades: trades_for(current_instrument),
          corporate_actions: corporate_actions_for(current_instrument),
          amount_for: ->(trade) { trade.total_amount }
        )
      end
    end

    def corporate_actions_for(current_instrument)
      user.corporate_actions.effective.quantity_actions
        .where(instrument: current_instrument, effective_on: ..to)
        .order(:effective_on, :id).to_a
    end

    def persist_candidate(current_instrument, candidate)
      source_reference = candidate.source_reference.to_s
      raise ArgumentError, "provider event reference is blank" if source_reference.empty?

      import = user.corporate_action_imports.find_by(source:, source_reference:)
      return persist_existing_import(import, current_instrument, candidate) if import

      persist_new_import(current_instrument, candidate, source_reference)
    end

    def persist_candidate_with_fence(current_instrument, candidate)
      return persist_candidate(current_instrument, candidate) unless fence

      persisted = fence.call { persist_candidate(current_instrument, candidate) }
      raise Superseded, "corporate-action scan generation was superseded" unless persisted

      persisted
    end

    def persist_existing_import(import, current_instrument, candidate)
      import.with_lock do
        persist_import(import, current_instrument, candidate, was_new: false)
      end
    end

    def persist_new_import(current_instrument, candidate, source_reference)
      imports = user.corporate_action_imports
      import = imports.new(source:, source_reference:)
      persist_import(import, current_instrument, candidate, was_new: true)
    rescue ActiveRecord::RecordNotUnique
      import = imports.find_by!(source:, source_reference:)
      import.with_lock do
        persist_import(import, current_instrument, candidate, was_new: false)
      end
    end

    def persist_import(import, current_instrument, candidate, was_new:)
      previous_status = import.status
      manually_reviewed = import.reviewed_at.present?
      confirmed = import.confirmed?
      changed_after_review = (confirmed || manually_reviewed) &&
        candidate_changed?(import, current_instrument, candidate)
      preserve_review = confirmed || import.ignored? || manually_reviewed
      warnings = assign_candidate(import, current_instrument, candidate, preserve_review:)
      apply_import_status(import, previous_status:, preserve_review:, changed_after_review:, warnings:)
      import.reviewed_at = nil if was_new
      import.save!
      [ import, was_new ]
    end

    def apply_import_status(import, previous_status:, preserve_review:, changed_after_review:, warnings:)
      if changed_after_review
        import.status = :conflict
        import.failure_message = "The provider payload changed after review; review it explicitly."
      elsif previous_status == "confirmed" || previous_status == "ignored"
        import.status = previous_status
      else
        import.status = if preserve_review
          :pending
        else
          warnings.include?("multiple_institutions") ? :ambiguous : :pending
        end
        import.failure_message = nil
      end
    end

    def assign_candidate(import, current_instrument, candidate, preserve_review: false)
      institution, institution_warning = institution_match_for(current_instrument)
      assign_instrument_attributes(import, current_instrument, institution, candidate, preserve_review:)
      warnings = candidate_warnings(current_instrument, candidate, institution_warning)
      import.warning_list = warnings
      warnings
    end

    def assign_instrument_attributes(import, current_instrument, institution, candidate, preserve_review:)
      assign_import_identity(import, current_instrument, institution, preserve_review:)
      assign_provider_attributes(import, candidate)
      assign_candidate_values(import, candidate) unless preserve_review
      assign_candidate_payload(import, candidate)
    end

    def assign_import_identity(import, current_instrument, institution, preserve_review:)
      import.instrument = current_instrument
      import.institution = institution unless preserve_review
      import.source = source
    end

    def assign_provider_attributes(import, candidate)
      import.provider_symbol = candidate.provider_symbol
      import.provider_exchange = candidate.provider_exchange
      import.amount_per_share = candidate.amount_per_share&.to_s("F")
    end

    def assign_candidate_payload(import, candidate)
      import.currency = candidate.currency
      import.normalized_candidate = normalized_candidate(candidate)
      import.raw_payload_hash = candidate.raw_payload
    end

    def assign_candidate_values(import, candidate)
      import.kind = candidate.kind
      event_on = candidate.event_on
      import.event_on = event_on
      import.ex_date = candidate.cash_action? ? event_on : nil
      assign_empty_cash_amounts(import)
      assign_candidate_ratio(import, candidate)
    end

    def assign_empty_cash_amounts(import)
      import.paid_on = nil
      import.gross_amount_cents = nil
      import.withholding_tax_cents = nil
      import.net_amount_cents = nil
    end

    def assign_candidate_ratio(import, candidate)
      import.ratio_numerator = candidate.ratio_numerator
      import.ratio_denominator = candidate.ratio_denominator
    end

    def candidate_warnings(current_instrument, candidate, institution_warning)
      duplicate_warning = manual_duplicate_warning_for(current_instrument, candidate)
      candidate.warnings + [ institution_warning, duplicate_warning ].compact
    end

    def manual_duplicate_warning_for(current_instrument, candidate)
      event_on = candidate.event_on
      return unless event_on

      "possible_duplicate" if manual_action_index_for(current_instrument).include?(
        kind: candidate.kind, date: event_on
      )
    end

    def manual_action_index_for(current_instrument)
      @manual_action_indices ||= {}
      instrument_id = current_instrument.id
      @manual_action_indices.fetch(instrument_id) do
        @manual_action_indices[instrument_id] = ManualActionIndex.new(
          user:, instrument: current_instrument
        )
      end
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
      JSON.generate(canonicalize(value))
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.sort_by(&:to_s).to_h { |key| [ key, canonicalize(value[key]) ] }
      when Array
        value.map { |entry| canonicalize(entry) }
      else
        value
      end
    end

    def default_provider
      Providers::YahooFinance.new
    end

    def validate_range!
      raise ArgumentError, "unsupported import source" unless Providers::SUPPORTED_SOURCES.include?(source)

      unless from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current
        raise ArgumentError, "import range must use past dates in chronological order"
      end
    end
  end
end
