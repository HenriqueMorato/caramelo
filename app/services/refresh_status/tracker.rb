module RefreshStatus
  class Tracker
    def self.enqueue(scope:, total_count: nil)
      run_id = SecureRandom.uuid
      completed = total_count == 0
      state = State.write(scope:, run_id:, status: completed ? "succeeded" : "queued", total_count:,
        finished_at: (Time.current if completed))
      Broadcaster.refresh
      state
    end

    def self.perform(scope:, total_count: nil, preserve_progress: false, run_id: nil)
      if preserve_progress && (existing = State.read(scope))
        return existing unless existing.active? && (run_id.nil? || existing.run_id == run_id)

        refresh = write(existing, status: "running", started_at: existing.started_at || Time.current)
        Broadcaster.refresh
        yield refresh
        return State.read(scope) || refresh
      end

      refresh = State.write(
        scope:, run_id: run_id || SecureRandom.uuid, status: "running", started_at: Time.current, total_count:
      )
      Broadcaster.refresh
      yield refresh
      refresh = State.read(refresh.scope)
      completed = refresh.total_count.nil? || refresh.processed_count >= refresh.total_count
      refresh = write(refresh, status: "succeeded", finished_at: Time.current) if completed && !refresh.failed?
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
      latest = State.read(refresh.scope) || refresh
      write(latest, status: "failed", finished_at: Time.current, error_class: error.class.name,
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
        run_id: refresh.run_id,
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
