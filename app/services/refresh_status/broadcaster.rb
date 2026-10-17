module RefreshStatus
  class Broadcaster
    STREAM_NAME = "refresh_status"
    TARGET = "refresh-status"
    ACTIVITY_TARGET = "health-refresh-activity"

    def self.refresh(state: nil, health: true, progress_only: false, owner: nil)
      if owner.nil? && Caramelo::AccountMode.multi?
        configured_users.each do |account|
          refresh(state:, health:, progress_only:, owner: account)
        end
        return
      end

      if progress_only
        broadcast_progress(owner:) if status_scope?(state&.scope)
      elsif status_scope?(state&.scope)
        broadcast_status(owner:)
      end
      return unless health && health_scope?(state&.scope)

      begin
        if owner
          MarketData::HealthReportBroadcaster.refresh(owner:)
        else
          MarketData::HealthReportBroadcaster.refresh
        end
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { source: "health_report_broadcast" })
      end
    end

    def self.stream_name(owner: nil)
      return STREAM_NAME unless owner && Caramelo::AccountMode.multi?

      "#{STREAM_NAME}:#{owner.id}"
    end

    def self.broadcast_status(owner: nil)
      status = Presenter.for
      Turbo::StreamsChannel.broadcast_update_to(
        stream_name(owner:), target: TARGET, partial: "refresh_status/status_content",
        locals: { status:, broadcast: true }, method: :morph
      )
      Turbo::StreamsChannel.broadcast_update_to(
        stream_name(owner:), target: ACTIVITY_TARGET, partial: "refresh_status/activity_content",
        locals: { status: }, method: :morph
      )
    end

    def self.broadcast_progress(owner: nil)
      label = Presenter.for.progress_label
      Turbo::StreamsChannel.broadcast_update_to(
        stream_name(owner:), target: "refresh-status-progress", partial: "refresh_status/progress",
        locals: { label:, parentheses: true }
      )
      Turbo::StreamsChannel.broadcast_update_to(
        stream_name(owner:), target: "health-refresh-progress", partial: "refresh_status/progress",
        locals: { label:, parentheses: false }
      )
    end

    def self.health_scope?(scope)
      scope.nil? || !hidden_scope?(scope)
    end

    def self.status_scope?(scope)
      scope.nil? || !hidden_scope?(scope)
    end

    def self.hidden_scope?(scope)
      scope.start_with?("current_market_price:") ||
        scope.start_with?("market_data_recovery:") ||
        scope.start_with?("corporate_action_imports_scan:")
    end

    def self.configured_users
      User.where.not(password_configured_at: nil).to_a
    end

    private_class_method :broadcast_status, :broadcast_progress, :health_scope?, :status_scope?, :hidden_scope?,
      :configured_users
  end
end
