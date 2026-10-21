require "test_helper"

class RefreshStatus::StateTest < ActiveSupport::TestCase
  test "writes and reads a refresh state from cache" do
    started_at = Time.current
    finished_at = started_at + 1.minute

    state = RefreshStatus::State.write(scope: "state_read", status: "succeeded", started_at:, finished_at:,
      processed_count: 2, total_count: 3)
    read_state = RefreshStatus::State.read("state_read")

    assert_equal state.scope, read_state.scope
    assert_equal state.status, read_state.status
    assert_equal started_at.to_i, read_state.started_at.to_i
    assert_equal finished_at.to_i, read_state.finished_at.to_i
    assert_equal "2/3", read_state.progress_label
    assert_predicate read_state, :frozen?
  end

  test "waits when another state writer owns the cache lock" do
    cache = ActiveSupport::Cache::MemoryStore.new
    attempts = 0
    original_write = cache.method(:write)
    cache.define_singleton_method(:write) do |key, *arguments, **options|
      if key.end_with?(":lock") && attempts.zero?
        attempts += 1
        false
      else
        original_write.call(key, *arguments, **options)
      end
    end

    with_stubbed_method(Rails, :cache, -> { cache }) do
      state = RefreshStatus::State.write(scope: "locked_state", status: "queued")
      assert_equal "queued", state.status
    end

    assert_equal 1, attempts
  end

  test "finds active, latest successful, and latest failed states" do
    RefreshStatus::State.write(scope: "active_state", status: "running", started_at: 2.minutes.ago)
    RefreshStatus::State.write(scope: "successful_state", status: "succeeded", finished_at: Time.current + 1.day)
    RefreshStatus::State.write(scope: "failed_state", status: "failed", finished_at: Time.current + 2.days)

    assert_includes RefreshStatus::State.active.map(&:scope), "active_state"
    assert_equal "successful_state", RefreshStatus::State.latest_successful.scope
    assert_equal "failed_state", RefreshStatus::State.latest_failed.scope
  end

  test "does not expose per-instrument refresh leases as global activity" do
    RefreshStatus::State.write(scope: "current_market_price:42", status: "running")
    RefreshStatus::State.write(scope: "market_data_recovery:1:run", status: "queued", total_count: 1)
    RefreshStatus::State.write(scope: "corporate_action_imports_scan:1:yahoo_finance:all:2026-08-01:2026-08-31", status: "running")
    RefreshStatus::State.write(scope: "manual_current_market_prices", status: "queued", total_count: 3)

    active_scopes = RefreshStatus::State.active.map(&:scope)
    assert_includes active_scopes, "manual_current_market_prices"
    refute_includes active_scopes, "current_market_price:42"
    refute_includes active_scopes, "market_data_recovery:1:run"
    refute_includes active_scopes, "corporate_action_imports_scan:1:yahoo_finance:all:2026-08-01:2026-08-31"
  end

  test "identifies running states" do
    assert_predicate RefreshStatus::State.new(
      scope: "running", run_id: nil, status: "running", started_at: nil, finished_at: nil,
      updated_at: nil, error_class: nil, error_message: nil, processed_count: 0, total_count: nil
    ), :running?
  end

  test "distinguishes queued and interrupted active states" do
    queued = RefreshStatus::State.new(
      scope: "queued", run_id: nil, status: "queued", started_at: Time.current,
      finished_at: nil, updated_at: Time.current, error_class: nil, error_message: nil,
      processed_count: 0, total_count: 1
    )
    interrupted = RefreshStatus::State.new(
      scope: queued.scope, run_id: queued.run_id, status: queued.status, started_at: queued.started_at,
      finished_at: nil, updated_at: 11.minutes.ago, error_class: nil, error_message: nil,
      processed_count: 0, total_count: 1
    )

    assert_predicate queued, :queued?
    refute_predicate queued, :interrupted?
    assert_predicate interrupted, :interrupted?
  end

  test "reports no progress when total is unknown" do
    state = RefreshStatus::State.write(scope: "unknown_total", status: "queued")

    assert_nil state.progress_label
  end

  test "ignores active states whose cache lease expired" do
    travel_to 11.minutes.ago do
      RefreshStatus::State.write(scope: "expired_state", status: "running", started_at: Time.current)
    end

    assert_empty RefreshStatus::State.active.select { |state| state.scope == "expired_state" }
  end

  test "prunes finished states older than the active timeout" do
    travel_to 11.minutes.ago do
      RefreshStatus::State.write(scope: "old_finished", status: "succeeded", finished_at: Time.current)
    end
    RefreshStatus::State.write(scope: "recent_finished", status: "succeeded", finished_at: Time.current)

    retained = RefreshStatus::State.prune!

    refute_includes retained, "old_finished"
    assert_includes retained, "recent_finished"
  end

  test "prunes unfinished states after their cache lease expires" do
    travel_to 11.minutes.ago do
      RefreshStatus::State.write(scope: "old_unfinished", status: "running", started_at: Time.current)
    end
    RefreshStatus::State.write(scope: "recent_unfinished", status: "running", started_at: Time.current)

    retained = RefreshStatus::State.prune!

    refute_includes retained, "old_unfinished"
    assert_includes retained, "recent_unfinished"
  end

  test "tracker records completion and failure" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      completed = RefreshStatus::Tracker.perform(scope: "tracked_success", total_count: 1) do |refresh|
        RefreshStatus::Tracker.advance(refresh)
      end

      assert_equal "succeeded", completed.status
      assert_equal 1, completed.processed_count

      assert_raises RuntimeError do
        RefreshStatus::Tracker.perform(scope: "tracked_failure") { raise "provider unavailable" }
      end

      failed = RefreshStatus::State.read("tracked_failure")
      assert_equal "failed", failed.status
      assert_equal "provider unavailable", failed.error_message
    end

    assert_equal "failed", RefreshStatus::State.read("tracked_failure").status
  end

  test "tracker preserves progress when a run fails after advancing" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      assert_raises RuntimeError do
        RefreshStatus::Tracker.perform(scope: "tracked_partial_failure", total_count: 3) do |refresh|
          RefreshStatus::Tracker.advance(refresh)
          raise "provider unavailable"
        end
      end
    end

    failed = RefreshStatus::State.read("tracked_partial_failure")
    assert_equal "failed", failed.status
    assert_equal 1, failed.processed_count
    assert_equal 3, failed.total_count
  end

  test "tracker preserves an existing batch while a child runs" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      RefreshStatus::Tracker.enqueue(scope: "tracked_batch", total_count: 2)
      RefreshStatus::Tracker.perform(scope: "tracked_batch", preserve_progress: true) do |refresh|
        RefreshStatus::Tracker.advance(refresh)
      end
    end

    state = RefreshStatus::State.read("tracked_batch")
    assert_equal "running", state.status
    assert_equal 1, state.processed_count
    assert_equal 2, state.total_count
  end

  test "tracker preserves a batch when its run id matches" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "matching_batch", total_count: 2)
      result = RefreshStatus::Tracker.perform(scope: "matching_batch", preserve_progress: true, run_id: state.run_id) { |refresh| refresh }

      assert_equal state.run_id, result.run_id
      assert_equal "running", result.status
    end
  end

  test "tracker ignores a child from a different run" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "stale_batch", total_count: 2)
      result = RefreshStatus::Tracker.perform(scope: "stale_batch", preserve_progress: true, run_id: "old-run") { flunk "stale child ran" }

      assert_equal state.run_id, result.run_id
      assert_equal "queued", result.status
    end
  end

  test "tracker does not reopen a successful run on duplicate delivery" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "duplicate_success", run_id: "same-run", total_count: 0)
      result = RefreshStatus::Tracker.perform(scope: "duplicate_success", run_id: state.run_id) { flunk "duplicate ran" }

      assert_equal "succeeded", result.status
      assert_equal state.run_id, result.run_id
    end
  end

  test "tracker ignores a stale run when it is not preserving progress" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "stale_run", total_count: 1)
      result = RefreshStatus::Tracker.perform(scope: "stale_run", run_id: "old-run") { flunk "stale run ran" }

      assert_equal state.run_id, result.run_id
      assert_equal "queued", result.status
    end
  end

  test "tracker ignores updates from a superseded run" do
    second = nil
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      first = RefreshStatus::Tracker.enqueue(scope: "superseded_batch", total_count: 2)
      second = RefreshStatus::Tracker.enqueue(scope: "superseded_batch", total_count: 2)

      RefreshStatus::Tracker.advance(first)
      RefreshStatus::Tracker.record_failure(first, RuntimeError.new("stale failure"))
    end

    current = RefreshStatus::State.read("superseded_batch")
    assert_equal second.run_id, current.run_id
    assert_equal "queued", current.status
    assert_equal 0, current.processed_count
  end

  test "state write does not replace a newer run when the expected run changed" do
    current = RefreshStatus::State.write(scope: "fenced_state", run_id: "new-run", status: "queued")

    stale = RefreshStatus::State.write(
      scope: current.scope, run_id: "old-run", status: "failed", expected_run_id: "old-run"
    )

    assert_nil stale
    assert_equal "new-run", RefreshStatus::State.read(current.scope).run_id
    assert_equal "queued", RefreshStatus::State.read(current.scope).status
  end

  test "state write can claim a scope only when no state exists" do
    assert RefreshStatus::State.write(
      scope: "unclaimed_state", run_id: "first-run", status: "queued", expected_run_id: RefreshStatus::State::NO_RUN
    )

    assert_nil RefreshStatus::State.write(
      scope: "unclaimed_state", run_id: "second-run", status: "queued", expected_run_id: RefreshStatus::State::NO_RUN
    )
    assert_equal "first-run", RefreshStatus::State.read("unclaimed_state").run_id
  end

  test "state write rejects an expected run when the scope is missing" do
    assert_nil RefreshStatus::State.write(
      scope: "missing_expected_state", run_id: "run", status: "queued", expected_run_id: "other-run"
    )
  end

  test "state release leaves a lock owned by another writer" do
    cache = ActiveSupport::Cache::MemoryStore.new
    scope = "foreign_lock"
    cache.write(RefreshStatus::State.send(:lock_key, scope), "other-writer")

    with_stubbed_method(Rails, :cache, -> { cache }) do
      assert_nil RefreshStatus::State.send(:release_lock, scope, "this-writer")
    end

    assert_equal "other-writer", cache.read(RefreshStatus::State.send(:lock_key, scope))
  end

  test "tracker does not yield after a newer run wins the start race" do
    original_write = RefreshStatus::State.method(:write)
    injected = false
    RefreshStatus::State.define_singleton_method(:write) do |**arguments|
      if arguments[:scope] == "start_race" && arguments[:status] == "running" && !injected
        injected = true
        original_write.call(scope: "start_race", run_id: "new-run", status: "queued")
      end
      original_write.call(**arguments)
    end

    yielded = false
    result = RefreshStatus::Tracker.perform(scope: "start_race", run_id: "old-run") do
      yielded = true
    end

    assert_not yielded
    assert_equal "new-run", result.run_id
    assert_equal "queued", result.status
  ensure
    RefreshStatus::State.define_singleton_method(:write, original_write)
  end

  test "tracker does not let a stale explicit enqueue replace the current run" do
    current = RefreshStatus::Tracker.enqueue(scope: "stale_enqueue", run_id: "new-run", supersede: true)

    result = RefreshStatus::Tracker.enqueue(scope: "stale_enqueue", run_id: "old-run")

    assert_equal current.run_id, result.run_id
    assert_equal "queued", result.status
  end

  test "tracker does not reopen a successful run on duplicate enqueue" do
    state = RefreshStatus::Tracker.enqueue(scope: "duplicate_enqueue", run_id: "same-run", total_count: 0)

    result = RefreshStatus::Tracker.enqueue(scope: "duplicate_enqueue", run_id: state.run_id, total_count: 2)

    assert_equal "succeeded", result.status
    assert_equal state.run_id, result.run_id
  end

  test "tracker does not preserve a terminal run" do
    state = RefreshStatus::Tracker.enqueue(scope: "terminal_preserve", total_count: 0)

    result = RefreshStatus::Tracker.perform(scope: state.scope, preserve_progress: true) { flunk "terminal run ran" }

    assert_equal "succeeded", result.status
  end

  test "tracker keeps the refresh when an advance write is fenced" do
    state = RefreshStatus::Tracker.enqueue(scope: "advance_fenced", total_count: 1)

    with_stubbed_method(RefreshStatus::Tracker, :write, ->(*, **) { nil }) do
      result = RefreshStatus::Tracker.advance(state)
      assert_equal state.scope, result.scope
      assert_equal state.run_id, result.run_id
    end
  end

  test "tracker keeps the refresh when a failure write is fenced" do
    state = RefreshStatus::Tracker.enqueue(scope: "failure_fenced", total_count: 1)

    with_stubbed_method(RefreshStatus::Tracker, :write, ->(*, **) { nil }) do
      result = RefreshStatus::Tracker.record_failure(state, RuntimeError.new("provider unavailable"))
      assert_equal state.scope, result.scope
      assert_equal state.run_id, result.run_id
    end
  end

  test "tracker ignores failure recording for a superseded refresh" do
    state = RefreshStatus::Tracker.enqueue(scope: "failure_stale_record", total_count: 1)
    RefreshStatus::Tracker.enqueue(scope: "failure_stale_record", run_id: "new-run", total_count: 1,
      supersede: true)

    result = RefreshStatus::Tracker.record_failure(state, RuntimeError.new("provider unavailable"))

    assert_equal state, result
    assert_equal "queued", RefreshStatus::State.read("failure_stale_record").status
  end

  test "tracker ignores failure recording after the refresh state disappears" do
    state = RefreshStatus::Tracker.enqueue(scope: "failure_missing_record", total_count: 1)
    Rails.cache.delete(RefreshStatus::State.send(:key, state.scope))

    result = RefreshStatus::Tracker.record_failure(state, RuntimeError.new("provider unavailable"))

    assert_equal state, result
    assert_nil RefreshStatus::State.read(state.scope)
  end

  test "tracker ignores completion after a newer run replaces the refresh" do
    result = nil
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      result = RefreshStatus::Tracker.perform(scope: "completion_stale") do
        RefreshStatus::Tracker.enqueue(scope: "completion_stale", total_count: 1)
      end
    end

    assert_nil result
    assert_equal "queued", RefreshStatus::State.read("completion_stale").status
  end

  test "tracker ignores failure recording after a newer run replaces the refresh" do
    assert_raises RuntimeError do
      RefreshStatus::Tracker.perform(scope: "failure_stale") do
        RefreshStatus::Tracker.enqueue(scope: "failure_stale", total_count: 1)
        raise "provider unavailable"
      end
    end

    assert_equal "queued", RefreshStatus::State.read("failure_stale").status
  end

  test "tracker keeps a failed refresh when the failure write is fenced" do
    assert_raises RuntimeError do
      with_stubbed_method(RefreshStatus::Tracker, :write, ->(*, **) { nil }) do
        RefreshStatus::Tracker.perform(scope: "failure_write_fenced") { raise "provider unavailable" }
      end
    end

    assert_equal "running", RefreshStatus::State.read("failure_write_fenced").status
  end

  test "tracker keeps the existing refresh when preserving progress is fenced" do
    state = RefreshStatus::Tracker.enqueue(scope: "preserve_write_fenced", total_count: 1)

    with_stubbed_method(RefreshStatus::Tracker, :write, ->(*, **) { nil }) do
      result = RefreshStatus::Tracker.perform(scope: state.scope, preserve_progress: true) do
        flunk "preserved refresh should not run"
      end

      assert_equal state.scope, result.scope
      assert_equal state.run_id, result.run_id
    end
  end

  test "tracker keeps a successful refresh when the completion write is fenced" do
    with_stubbed_method(RefreshStatus::Tracker, :write, ->(*, **) { nil }) do
      assert_nil RefreshStatus::Tracker.perform(scope: "completion_write_fenced") { }
    end

    assert_equal "running", RefreshStatus::State.read("completion_write_fenced").status
  end

  test "tracker starts a new state when preserving a missing batch" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      RefreshStatus::Tracker.perform(scope: "missing_batch", total_count: 1, preserve_progress: true) { }
    end

    assert_equal "running", RefreshStatus::State.read("missing_batch").status
  end

  test "tracker marks a refresh as queued" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "queued_state", total_count: 4)

      assert_equal "queued", state.status
      assert_equal "queued", RefreshStatus::State.read("queued_state").status
    end
  end

  test "tracker completes an empty batch immediately" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "empty_batch", total_count: 0)

      assert_equal "succeeded", state.status
      assert_equal 0, state.processed_count
      assert state.finished_at
    end
  end

  test "tracker preserves progress when recording a failure" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "failed_batch", total_count: 2)
      RefreshStatus::Tracker.advance(state)
      RefreshStatus::Tracker.record_failure(state, RuntimeError.new("provider unavailable"))
    end

    state = RefreshStatus::State.read("failed_batch")
    assert_equal "failed", state.status
    assert_equal 1, state.processed_count
    assert_equal 2, state.total_count
  end

  test "tracker advances a failed batch without rebuilding health" do
    broadcasts = []
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**arguments) { broadcasts << arguments }) do
      state = RefreshStatus::Tracker.enqueue(scope: "failed_progress", total_count: 2)
      RefreshStatus::Tracker.record_failure(state, RuntimeError.new("provider unavailable"))
      RefreshStatus::Tracker.record_failure(state, RuntimeError.new("provider unavailable again"))
      RefreshStatus::Tracker.advance(state)
    end

    state = RefreshStatus::State.read("failed_progress")
    assert_equal "failed", state.status
    assert_equal 1, state.processed_count
    assert_equal [ true, true, false, false ], broadcasts.map { |call| call.fetch(:health) }
    assert_equal [ false, false, true, true ], broadcasts.map { |call| call.fetch(:progress_only) }
  end

  test "tracker rebuilds health only for meaningful lifecycle transitions" do
    broadcasts = []
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**arguments) { broadcasts << arguments }) do
      refresh = RefreshStatus::Tracker.enqueue(scope: "progress_lifecycle", total_count: 2)
      RefreshStatus::Tracker.advance(refresh)
      RefreshStatus::Tracker.advance(refresh)
    end

    assert_equal [ true, false, true ], broadcasts.map { |call| call.fetch(:health) }
    assert_equal %w[queued queued succeeded], broadcasts.map { |call| call.fetch(:state).status }
    assert_equal [ false, true, false ], broadcasts.map { |call| call.fetch(:progress_only) }
  end

  test "tracker ignores failures for unknown scopes" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      assert_nil RefreshStatus::Tracker.fail(scope: "unknown_failure", error: RuntimeError.new("missing"))
    end
  end

  test "tracker still broadcasts when setup fails before a state exists" do
    broadcasts = 0
    with_stubbed_method(RefreshStatus::State, :write, ->(**) { raise "cache unavailable" }) do
      with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { broadcasts += 1 }) do
        assert_raises RuntimeError do
          RefreshStatus::Tracker.perform(scope: "unavailable_state") { }
        end
      end
    end

    assert_equal 1, broadcasts
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end
end
