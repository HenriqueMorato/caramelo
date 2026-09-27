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
          fetch_from = [ from, trades_for(current_instrument).first.traded_on ].max
          @provider.fetch(instrument: current_instrument, from: fetch_from, to:).each do |candidate|
            next unless candidate_has_position?(current_instrument, candidate)

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
      if instrument
        unless user.trades.where(instrument_id: instrument.id, traded_on: ..to).exists?
          raise ArgumentError, "instrument is not traded by this owner"
        end

        return [ instrument ]
      end

      instrument_ids = user.trades.where(traded_on: ..to).distinct.pluck(:instrument_id)
      Instrument.where(id: instrument_ids).alphabetical.to_a
    end

    def trades_for(current_instrument)
      @trades_by_instrument ||= {}
      @trades_by_instrument.fetch(current_instrument.id) do
        @trades_by_instrument[current_instrument.id] = user.trades
          .where(instrument: current_instrument, traded_on: ..to)
          .order(:traded_on, :id).to_a
      end
    end

    def candidate_has_position?(current_instrument, candidate)
      return true unless candidate.event_on

      quantity = 0.to_r
      quantity_timeline_for(current_instrument).each do |event_date, event_quantity|
        break if event_date > candidate.event_on

        quantity = event_quantity
      end
      quantity.positive?
    rescue Position::InvalidLongOnlyData, Position::InvalidQuantityActionData
      # Preserve the review item when existing ledger data cannot be replayed safely.
      true
    end

    def quantity_timeline_for(current_instrument)
      @quantity_timelines ||= {}
      @quantity_timelines.fetch(current_instrument.id) do
        @quantity_timelines[current_instrument.id] = Position::Calculator.quantity_timeline(
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

    def persist_existing_import(import, current_instrument, candidate)
      import.with_lock do
        persist_import(import, current_instrument, candidate, was_new: false)
      end
    end

    def persist_new_import(current_instrument, candidate, source_reference)
      import = user.corporate_action_imports.new(source:, source_reference:)
      persist_import(import, current_instrument, candidate, was_new: true)
    rescue ActiveRecord::RecordNotUnique
      import = user.corporate_action_imports.find_by!(source:, source_reference:)
      import.with_lock do
        persist_import(import, current_instrument, candidate, was_new: false)
      end
    end

    def persist_import(import, current_instrument, candidate, was_new:)
      previous_status = import.status
      manually_reviewed = import.reviewed_at.present?
      changed_after_review = (import.confirmed? || manually_reviewed) &&
        candidate_changed?(import, current_instrument, candidate)
      preserve_review = import.confirmed? || import.ignored? || manually_reviewed
      warnings = assign_candidate(import, current_instrument, candidate, preserve_review:)
      if changed_after_review
        import.status = :conflict
        import.failure_message = "The provider payload changed after review; review it explicitly."
      elsif previous_status == "confirmed" || previous_status == "ignored"
        import.status = previous_status
      elsif preserve_review
        import.status = :pending
        import.failure_message = nil
      else
        import.status = warnings.include?("multiple_institutions") ? :ambiguous : :pending
        import.failure_message = nil
      end
      import.reviewed_at = nil if was_new
      import.save!
      [ import, was_new ]
    end

    def assign_candidate(import, current_instrument, candidate, preserve_review: false)
      institution, institution_warning = institution_match_for(current_instrument)
      duplicate_warning = manual_duplicate_warning_for(current_instrument, candidate)
      import.instrument = current_instrument
      import.institution = institution unless preserve_review
      import.source = source
      import.provider_symbol = candidate.provider_symbol
      import.provider_exchange = candidate.provider_exchange
      import.amount_per_share = candidate.amount_per_share&.to_s("F")
      unless preserve_review
        import.kind = candidate.kind
        import.event_on = candidate.event_on
        import.ex_date = candidate.cash_action? ? candidate.event_on : nil
        import.paid_on = nil
        import.gross_amount_cents = nil
        import.withholding_tax_cents = nil
        import.net_amount_cents = nil
        import.ratio_numerator = candidate.ratio_numerator
        import.ratio_denominator = candidate.ratio_denominator
      end
      import.currency = candidate.currency
      import.normalized_candidate = normalized_candidate(candidate)
      import.raw_payload_hash = candidate.raw_payload
      warnings = candidate.warnings + [ institution_warning, duplicate_warning ].compact
      import.warning_list = warnings
      warnings
    end

    def manual_duplicate_warning_for(current_instrument, candidate)
      return unless candidate.event_on

      key = [ normalized_action_kind(candidate.kind), candidate.event_on ]
      "possible_duplicate" if manual_action_keys_for(current_instrument).key?(key)
    end

    def manual_action_keys_for(current_instrument)
      @manual_action_keys_by_instrument ||= {}
      @manual_action_keys_by_instrument.fetch(current_instrument.id) do
        keys = user.corporate_actions.where(
          instrument: current_instrument, source: "manual"
        ).where.not(status: :reversed).pluck(:kind, :effective_on, :ex_date, :paid_on).each_with_object({}) do |row, result|
          kind, effective_on, ex_date, paid_on = row
          [ effective_on, ex_date, paid_on ].compact.uniq.each do |date|
            result[[ normalized_action_kind(kind), date ]] = true
          end
        end
        @manual_action_keys_by_instrument[current_instrument.id] = keys
      end
    end

    def normalized_action_kind(kind)
      return "split" if CorporateActionImport.stock_split_kind?(kind)

      kind.to_s
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
      raise ArgumentError, "unsupported import source" unless source == "yahoo_finance"

      unless from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current
        raise ArgumentError, "import range must use past dates in chronological order"
      end
    end
  end
end
