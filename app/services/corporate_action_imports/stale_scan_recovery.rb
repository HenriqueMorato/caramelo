module CorporateActionImports
  class StaleScanRecovery
    STALE_AFTER = 5.minutes

    Result = Data.define(:recovered_count, :changed_count) do
      def recovered? = recovered_count.positive?
      def changed? = changed_count.positive?
    end

    def self.call(now: Time.current, stale_after: STALE_AFTER, queue_activity: MarketData::QueueActivity,
      scan_scope: nil)
      new(now:, stale_after:, queue_activity:, scan_scope:).call
    end

    def initialize(now:, stale_after:, queue_activity:, scan_scope: nil)
      @now = now
      @stale_after = stale_after
      @queue_activity = queue_activity
      @scan_scope = scan_scope
    end

    def call
      outcomes = scans.filter_map { |scan| recover(scan) }
      Result.new(
        recovered_count: outcomes.count(:recovered),
        changed_count: outcomes.length
      )
    end

    private

    attr_reader :now, :stale_after, :queue_activity, :scan_scope

    def scans
      scan_scope || CorporateActionImportScan.where(status: %w[queued running]).includes(:user, :instrument).to_a
    end

    def recover(scan)
      return false unless scan.active_expired?(at: now, timeout: stale_after)
      return false if active_job?(scan)

      result = CorporateActionImports::Automation.call(
        user: scan.user, instrument: scan.instrument, source: scan.source, today: now.to_date,
        stale_timeout: stale_after
      )
      result.scheduled? ? :recovered : (result.failed? ? :changed : false)
    rescue StandardError => error
      Rails.error.report(
        error, handled: true,
        context: { source: "stale_corporate_action_scan_recovery", scan_id: scan&.id }
      )
      false
    end

    def active_job?(scan)
      queue_activity.active_job?(class_name: ScanCorporateActionImportsJob.name) do |arguments|
        arguments[:automation_scan_id].to_i == scan.id &&
          arguments[:automation_run_id].to_s == scan.run_id.to_s
      end
    end
  end
end
