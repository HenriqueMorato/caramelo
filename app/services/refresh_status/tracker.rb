module RefreshStatus
  class Tracker
    def self.enqueue(scope:, total_count: nil)
      state = State.write(scope:, status: "queued", total_count:)
      Broadcaster.refresh
      state
    end

    def self.perform(scope:, total_count: nil)
      refresh = State.write(scope:, status: "running", started_at: Time.current, total_count:)
      Broadcaster.refresh
      yield refresh
      refresh = State.read(refresh.scope)
      refresh = write(refresh, status: "succeeded", finished_at: Time.current) unless refresh.failed?
      Broadcaster.refresh
      refresh
    rescue StandardError => error
      write(refresh, status: "failed", finished_at: Time.current, error_class: error.class.name,
        error_message: error.message.truncate(500)) if refresh
      Broadcaster.refresh
      raise
    end

    def self.advance(refresh)
      latest = State.read(refresh.scope) || refresh
      processed_count = latest.processed_count + 1
      if latest.total_count && processed_count >= latest.total_count && !latest.failed?
        write(latest, status: "succeeded", finished_at: Time.current, processed_count:)
      else
        write(latest, processed_count:)
      end
      Broadcaster.refresh
    end

    def self.record_failure(refresh, error)
      write(refresh, status: "failed", finished_at: Time.current, error_class: error.class.name,
        error_message: error.message.truncate(500))
      Broadcaster.refresh
    end

    def self.fail(scope:, error:)
      refresh = State.read(scope)
      return unless refresh

      record_failure(refresh, error)
    end

    def self.write(refresh, **attributes)
      State.write(
        scope: refresh.scope,
        status: attributes.fetch(:status, refresh.status),
        started_at: attributes.fetch(:started_at, refresh.started_at),
        finished_at: attributes.fetch(:finished_at, refresh.finished_at),
        error_class: attributes.fetch(:error_class, refresh.error_class),
        error_message: attributes.fetch(:error_message, refresh.error_message),
        processed_count: attributes.fetch(:processed_count, refresh.processed_count),
        total_count: attributes.fetch(:total_count, refresh.total_count)
      )
    end

    private_class_method :new
  end
end
