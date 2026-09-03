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
    RefreshStatus::State.write(scope: "manual_current_market_prices", status: "queued", total_count: 3)

    active_scopes = RefreshStatus::State.active.map(&:scope)
    assert_includes active_scopes, "manual_current_market_prices"
    refute_includes active_scopes, "current_market_price:42"
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

  test "tracker records completion and failure" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { }) do
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

  test "tracker preserves an existing batch while a child runs" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { }) do
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
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "matching_batch", total_count: 2)
      result = RefreshStatus::Tracker.perform(scope: "matching_batch", preserve_progress: true, run_id: state.run_id) { |refresh| refresh }

      assert_equal state.run_id, result.run_id
      assert_equal "running", result.status
    end
  end

  test "tracker ignores a child from a different run" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "stale_batch", total_count: 2)
      result = RefreshStatus::Tracker.perform(scope: "stale_batch", preserve_progress: true, run_id: "old-run") { flunk "stale child ran" }

      assert_equal state.run_id, result.run_id
      assert_equal "queued", result.status
    end
  end

  test "tracker starts a new state when preserving a missing batch" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { }) do
      RefreshStatus::Tracker.perform(scope: "missing_batch", total_count: 1, preserve_progress: true) { }
    end

    assert_equal "running", RefreshStatus::State.read("missing_batch").status
  end

  test "tracker marks a refresh as queued" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "queued_state", total_count: 4)

      assert_equal "queued", state.status
      assert_equal "queued", RefreshStatus::State.read("queued_state").status
    end
  end

  test "tracker completes an empty batch immediately" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "empty_batch", total_count: 0)

      assert_equal "succeeded", state.status
      assert_equal 0, state.processed_count
      assert state.finished_at
    end
  end

  test "tracker preserves progress when recording a failure" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { }) do
      state = RefreshStatus::Tracker.enqueue(scope: "failed_batch", total_count: 2)
      RefreshStatus::Tracker.advance(state)
      RefreshStatus::Tracker.record_failure(state, RuntimeError.new("provider unavailable"))
    end

    state = RefreshStatus::State.read("failed_batch")
    assert_equal "failed", state.status
    assert_equal 1, state.processed_count
    assert_equal 2, state.total_count
  end

  test "tracker ignores failures for unknown scopes" do
    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { }) do
      assert_nil RefreshStatus::Tracker.fail(scope: "unknown_failure", error: RuntimeError.new("missing"))
    end
  end

  test "tracker still broadcasts when setup fails before a state exists" do
    broadcasts = 0
    with_stubbed_method(RefreshStatus::State, :write, ->(**) { raise "cache unavailable" }) do
      with_stubbed_method(RefreshStatus::Broadcaster, :refresh, -> { broadcasts += 1 }) do
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
