module MarketData
  class HealthReportBroadcaster
    STREAM_PREFIX = "market_data_health"
    TARGET = "health-report"

    def self.refresh(report: nil, owner: nil)
      if owner.nil? && report.nil? && Caramelo::AccountMode.multi?
        configured_users.each { |account| refresh(owner: account) }
        return
      end

      owner ||= User.owner
      report ||= HealthReport.for(owner:)
      HealthReportPresenter::FILTERS.each do |status_filter|
        presenter = HealthReportPresenter.new(report:, owner:, status_filter:)
        Turbo::StreamsChannel.broadcast_replace_to(
          stream_name(status_filter, owner:),
          target: TARGET,
          partial: "market_data_health/report",
          locals: { report:, health: presenter, entries: presenter.entries },
          method: :morph
        )
      end
      Turbo::StreamsChannel.broadcast_update_to(
        RefreshStatus::Broadcaster.stream_name(owner:),
        target: RefreshStatus::Broadcaster::ACTIVITY_TARGET,
        partial: "refresh_status/activity_content",
        locals: { status: RefreshStatus::Presenter.for(report:) },
        method: :morph
      )
    end

    def self.stream_name(status_filter, owner: nil)
      suffix = owner && Caramelo::AccountMode.multi? ? "#{owner.id}:" : ""
      "#{STREAM_PREFIX}:#{suffix}#{status_filter}"
    end

    def self.configured_users
      User.where.not(password_configured_at: nil).to_a
    end

    private_class_method :configured_users
  end
end
