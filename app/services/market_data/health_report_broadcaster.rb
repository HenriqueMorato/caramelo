module MarketData
  class HealthReportBroadcaster
    STREAM_NAME = RefreshStatus::Broadcaster::STREAM_NAME

    def self.refresh(report: HealthReport.for, presenter: nil)
      presenter ||= HealthReportPresenter.new(report:)
      report.entries.each do |entry|
        Turbo::StreamsChannel.broadcast_replace_to(
          STREAM_NAME,
          target: entry.dom_id,
          partial: "market_data_health/entry",
          locals: { entry:, health: presenter }
        )
      end
    end
  end
end
