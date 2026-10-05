module MarketData
  class HealthReport
    class CorporateActionImports
      def initialize(owner:, today:)
        @owner = owner
        @today = today
      end

      def entries
        first_trade_dates = owner.trades.where(traded_on: ..today).group(:instrument_id).minimum(:traded_on)
        owner.corporate_action_import_scans.where(instrument_id: first_trade_dates.keys)
          .includes(:instrument).order(:instrument_id, :source).map do |scan|
          entry_for(scan, first_trade_on: first_trade_dates[scan.instrument_id])
        end
      end

      private

      attr_reader :owner, :today

      def entry_for(scan, first_trade_on:)
        status = status_for(scan)
        HealthReport::Entry.new(
          code: :corporate_action_imports,
          status:,
          severity: status == :failed ? :error : (%i[missing stale].include?(status) ? :warning : nil),
          subject: scan.instrument,
          label: "#{scan.instrument.ticker} provider events · #{scan.source}",
          description: description(scan, status),
          target: Target.new(kind: :corporate_action_imports, record_id: scan.instrument_id, provider: scan.source),
          actions: %i[healthy updating].include?(status) ? [] : [ :retry ],
          observed_on: scan.scanned_through,
          fetched_at: scan.completed_at,
          covered_range: covered_range(scan, first_trade_on:),
          missing_range: missing_range(scan)
        )
      end

      def status_for(scan)
        return :failed if scan.failed? || scan.active_expired?
        return :updating if scan.pending? || scan.active?
        return :stale if scan.scanned_through.nil? || scan.scanned_through < today

        :healthy
      end

      def description(scan, status)
        return "#{scan.instrument.ticker} provider scan lease expired before completion." if scan.active_expired?
        return "#{scan.instrument.ticker} provider scan failed: #{scan.failure_message}." if status == :failed
        return "#{scan.instrument.ticker} provider scan is queued or running." if status == :updating
        return "#{scan.instrument.ticker} provider scan has not completed through today." if status == :stale

        "#{scan.instrument.ticker} provider events are checked through #{scan.scanned_through}."
      end

      def covered_range(scan, first_trade_on:)
        return unless scan.scanned_through

        first_trade_on..scan.scanned_through if first_trade_on
      end

      def missing_range(scan)
        return unless scan.scanned_through && scan.scanned_through < today

        (scan.scanned_through + 1.day)..today
      end
    end
  end
end
