module MarketData
  class HealthReportPresenter
    FILTERS = %w[all attention healthy].freeze

    attr_reader :report, :status_filter

    def initialize(report:, status_filter: "all", preview_factory: ResetPreview)
      @report = report
      @status_filter = FILTERS.include?(status_filter) ? status_filter : "all"
      @reset_previews = build_reset_previews(preview_factory)
    end

    def entries
      @entries ||= case status_filter
      when "attention" then report.entries.reject(&:healthy?)
      when "healthy" then report.entries.select(&:healthy?)
      else report.entries
      end
    end

    def reset_preview_for(entry)
      @reset_previews[entry.target.record_id]
    end

    def healthy? = report.healthy?
    def issue_count = report.issues.size

    def status_label(entry)
      entry.status.to_s.humanize
    end

    def status_class(entry)
      return "text-leaf" if entry.healthy?
      return "text-guava" if entry.severity == :error

      "text-caramel-deep"
    end

    private

    def build_reset_previews(preview_factory)
      report.entries.filter_map do |entry|
        next unless entry.quote_reset_needed? && entry.target.provider

        [ entry.target.record_id, preview_factory.create(target: entry.target) ]
      end.to_h
    end
  end
end
