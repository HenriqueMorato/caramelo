module RefreshStatus
  class Tracker
    def self.enqueue(scope:, total_count: nil, run_id: nil, supersede: false)
      explicit_run_id = run_id.present?
      current = State.read(scope)
      current_run_id = current&.run_id
      return current if explicit_run_id && !supersede && current && current_run_id != run_id
      return current if explicit_run_id && current_run_id == run_id && current.status == "succeeded"

      run_id ||= SecureRandom.uuid
      completed = total_count == 0
      state = State.write(
        scope:, run_id:, status: completed ? "succeeded" : "queued", total_count:,
        finished_at: (Time.current if completed), expected_run_id: current ? current.run_id : State::NO_RUN
      )
      state ||= State.read(scope) || current
      broadcast(state)
    end

    def self.perform(scope:, total_count: nil, preserve_progress: false, run_id: nil)
      existing = State.read(scope)
      existing_run_id = existing&.run_id
      return existing if run_id && existing && existing_run_id != run_id
      return existing if run_id && existing&.status == "succeeded"

      if preserve_progress && existing
        refresh = existing
        return preserve(existing, run_id:) { |state| yield state }
      end

      expected_run_id = existing ? existing.run_id : State::NO_RUN
      refresh = start(scope:, total_count:, run_id:, expected_run_id:)
      return State.read(scope) || existing unless refresh

      yield refresh
      complete(refresh)
    rescue StandardError => error
      refresh ? fail_refresh(refresh, error) : Broadcaster.refresh(health: false)
      raise
    end

    def self.advance(refresh)
      latest = current_state(refresh)
      return refresh unless latest

      processed_count = latest.processed_count + 1
      failed = latest.failed?
      total_count = latest.total_count
      completed = total_count && processed_count >= total_count && !failed
      latest = if completed
        write(latest, status: "succeeded", finished_at: Time.current, processed_count:)
      else
        write(latest, processed_count:)
      end
      return refresh unless latest

      finished = latest.finished_at.present?
      broadcast(latest, health: finished && !failed, progress_only: !finished || failed)
    end

    def self.record_failure(refresh, error)
      latest = current_state(refresh)
      return refresh unless latest

      already_failed = latest.failed?
      latest = write(latest, status: "failed", finished_at: Time.current, error_class: error.class.name,
        error_message: error.message.truncate(500))
      return refresh unless latest

      broadcast(latest, health: !already_failed, progress_only: already_failed)
    end

    def self.fail(scope:, error:, run_id: nil)
      refresh = State.read(scope)
      return if refresh.nil? || (run_id && refresh.run_id != run_id)

      record_failure(refresh, error)
    end

    def self.write(refresh, **attributes)
      run_id = refresh.run_id
      State.write(
        scope: refresh.scope,
        run_id:,
        status: attributes.fetch(:status, refresh.status),
        started_at: attributes.fetch(:started_at, refresh.started_at),
        finished_at: attributes.fetch(:finished_at, refresh.finished_at),
        error_class: attributes.fetch(:error_class, refresh.error_class),
        error_message: attributes.fetch(:error_message, refresh.error_message),
        processed_count: attributes.fetch(:processed_count, refresh.processed_count),
        total_count: attributes.fetch(:total_count, refresh.total_count), expected_run_id: run_id
      )
    end

    private_class_method :new

    def self.broadcast(state = nil, health: true, progress_only: false)
      Broadcaster.refresh(state:, health:, progress_only:)
      state
    end

    def self.start(scope:, total_count:, run_id:, expected_run_id:)
      State.write(
        scope:, run_id: run_id || SecureRandom.uuid, status: "running", started_at: Time.current, total_count:,
        expected_run_id:
      )
    end

    def self.preserve(existing, run_id:)
      return existing unless existing.active? && (run_id.nil? || existing.run_id == run_id)

      refresh = write(existing, status: "running", started_at: existing.started_at || Time.current)
      return State.read(existing.scope) || existing unless refresh

      yield refresh
      State.read(refresh.scope) || refresh
    end

    def self.complete(refresh)
      refresh = current_state(refresh)
      return unless refresh

      total_count = refresh.total_count
      completed = total_count.nil? || refresh.processed_count >= total_count
      if completed && !refresh.failed?
        refresh = write(refresh, status: "succeeded", finished_at: Time.current)
        return unless refresh
      end
      broadcast(refresh, health: refresh.finished_at.present?)
    end

    def self.fail_refresh(refresh, error)
      latest = current_state(refresh)
      return unless latest

      already_failed = latest.failed?
      latest = write(latest, status: "failed", finished_at: Time.current, error_class: error.class.name,
        error_message: error.message.truncate(500))
      return unless latest

      broadcast(latest, health: !already_failed)
    end

    def self.current_state(refresh)
      latest = State.read(refresh.scope)
      latest if latest && latest.run_id == refresh.run_id
    end

    def self.current?(refresh)
      current_state(refresh).present?
    end

    private_class_method :broadcast, :start, :preserve, :complete, :fail_refresh, :current_state
  end
end
