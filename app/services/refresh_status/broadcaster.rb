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
    end
  end
end
