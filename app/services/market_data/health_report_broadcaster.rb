module MarketData
  class HealthReportBroadcaster
    STREAM_PREFIX = "market_data_health"
    TARGET = "health-report"

    def self.refresh(report: HealthReport.for)
      HealthReportPresenter::FILTERS.each do |status_filter|
        presenter = HealthReportPresenter.new(report:, status_filter:)
        Turbo::StreamsChannel.broadcast_replace_to(
          stream_name(status_filter),
          target: TARGET,
          partial: "market_data_health/report",
          locals: { report:, health: presenter, entries: presenter.entries },
          method: :morph
        )
      end
      Turbo::StreamsChannel.broadcast_update_to(
        RefreshStatus::Broadcaster::STREAM_NAME,
        target: RefreshStatus::Broadcaster::ACTIVITY_TARGET,
        partial: "refresh_status/activity_content",
        locals: { status: RefreshStatus::Presenter.for(report:) },
        method: :morph
      )
    end

    def self.stream_name(status_filter)
      "#{STREAM_PREFIX}:#{status_filter}"
    end
  end
end
