module RefreshStatus
  class Broadcaster
    STREAM_NAME = "refresh_status"
    TARGET = "refresh-status"

    def self.refresh
      Turbo::StreamsChannel.broadcast_replace_to(
        STREAM_NAME,
        target: TARGET,
        partial: "refresh_status/status",
        locals: { status: Presenter.for, broadcast: true }
      )
      begin
        MarketData::HealthReportBroadcaster.refresh
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { source: "health_report_broadcast" })
      end
    end
  end
end
