module MarketData
  class HealthReport
    class AssetTypePerformance
      STATUS_PRIORITY = %i[failed interrupted updating missing partial stale healthy].freeze

      def initialize(owner:, today:, context:, instrument_entries:)
        @owner = owner
        @today = today
        @context = context
        @instrument_entries = instrument_entries
      end

      def entries
        instruments_by_type.filter_map do |asset_type, instruments|
          build_entry(asset_type:, instruments:)
        end
      end

      private

      attr_reader :owner, :today, :context, :instrument_entries

      def instruments_by_type
        context.performance_instruments.group_by(&:asset_type)
      end

      def build_entry(asset_type:, instruments:)
        statuses = instruments.map { |instrument| entry_for(instrument) }
        status = aggregate_status(statuses)
        label = "#{asset_type_label(asset_type)} performance · #{owner.reporting_currency}"

        HealthReport::Entry.new(
          code: :asset_type_performance,
          status:,
          severity: severity_for(status),
          subject: asset_type,
          label:,
          description: description(label:, status:, entries: statuses),
          target: Target.new(
            kind: :asset_type_performance,
            record_id: asset_type,
            quote_currency: owner.reporting_currency
          ),
          actions: [],
          observed_on: nil,
          fetched_at: nil,
          covered_range: covered_range(statuses),
          missing_range: missing_range(statuses)
        )
      end

      def entry_for(instrument)
        performance_entries_by_instrument[instrument]
      end

      def performance_entries_by_instrument
        @performance_entries_by_instrument ||= instrument_entries.filter_map do |entry|
          next unless entry.code == :instrument_performance
          next unless entry.target.quote_currency == owner.reporting_currency

          [ entry.subject, entry ]
        end.to_h
      end

      def aggregate_status(entries)
        statuses = entries.map { |entry| entry&.status || :missing }
        STATUS_PRIORITY.find { |status| statuses.include?(status) } || :healthy
      end

      def severity_for(status)
        return :error if %i[failed interrupted].include?(status)
        return :warning if %i[missing partial stale].include?(status)

        nil
      end

      def description(label:, status:, entries:)
        return "#{label} is ready for Asset mode." if status == :healthy
        return "#{label} is rebuilding for Asset mode." if status == :updating
        return "#{label} failed to rebuild." if status == :failed
        return "#{label} refresh stopped before completing." if status == :interrupted
        return "#{label} has stale last-known values." if status == :stale

        ranges = entries.filter_map { |entry| entry&.missing_range }
        return "#{label} is missing values for the underlying instruments." if ranges.empty?

        "#{label} is missing values for #{format_ranges(ranges)}."
      end

      def covered_range(entries)
        ranges = entries.filter_map { |entry| entry&.covered_range }
        return if ranges.empty?

        ranges.map(&:begin).min..ranges.map(&:end).max
      end

      def missing_range(entries)
        ranges = entries.filter_map { |entry| entry&.missing_range }
        return if ranges.empty?

        ranges.map(&:begin).min..ranges.map(&:end).max
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end

      def asset_type_label(asset_type)
        I18n.t("instrument_types.#{asset_type}", default: asset_type.humanize)
      end
    end
  end
end
