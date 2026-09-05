require "test_helper"

class MarketDataRecoveriesBatchProgressTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @state = RefreshStatus::Tracker.enqueue(scope: "batch_progress", total_count: 1)
  end

  test "advances a matching active batch" do
    MarketData::Recoveries::BatchProgress.advance(scope: @state.scope, run_id: @state.run_id)

    assert_equal "succeeded", RefreshStatus::State.read(@state.scope).status
  end

  test "ignores missing or stale batches" do
    assert_nil MarketData::Recoveries::BatchProgress.advance(scope: "missing", run_id: "run")
    assert_nil MarketData::Recoveries::BatchProgress.advance(scope: @state.scope, run_id: "other")
  end

  test "records failure for a matching active batch" do
    error = RuntimeError.new("failed")
    MarketData::Recoveries::BatchProgress.fail(scope: @state.scope, run_id: @state.run_id, error:)

    assert_equal "failed", RefreshStatus::State.read(@state.scope).status
  end

  test "ignores failure for missing or stale batches" do
    error = RuntimeError.new("failed")
    assert_nil MarketData::Recoveries::BatchProgress.fail(scope: "missing", run_id: "run", error:)
    assert_nil MarketData::Recoveries::BatchProgress.fail(scope: @state.scope, run_id: "other", error:)
  end
end
