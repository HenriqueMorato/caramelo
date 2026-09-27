require "test_helper"

class CorporateActionImports::ScanStatusTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
    @from = Date.new(2026, 8, 1)
    @to = Date.new(2026, 8, 31)
    @scope = described_class.scope(
      user: @user, from: @from, to: @to, source: "yahoo_finance", instrument_id: nil
    )
  end

  test "builds stable scopes, streams, and retry paths" do
    instrument_scope = described_class.scope(
      user: @user, from: @from, to: @to, source: "yahoo_finance", instrument_id: instruments(:voo_arcx).id
    )

    assert_equal "corporate_action_imports_scan:#{@user.id}:yahoo_finance:all:2026-08-01:2026-08-31", @scope
    assert_not_equal described_class.stream_name(@scope), described_class.stream_name(instrument_scope)
    assert_match %r{/corporate-action-imports\?}, described_class.path(
      from: @from, to: @to, source: "yahoo_finance"
    )
    assert_includes described_class.path(
      from: @from, to: @to, source: "yahoo_finance", instrument_id: 42, run_id: "run-1"
    ), "instrument_id=42"
    assert_includes described_class.path(
      from: @from, to: @to, source: "yahoo_finance", instrument_id: 42, run_id: "run-1"
    ), "scan_run_id=run-1"
  end

  test "tracks the complete lifecycle" do
    queued = described_class.enqueue(scope: @scope)
    assert_equal "queued", queued.status
    assert_equal queued.run_id, RefreshStatus::State.read(@scope).run_id

    running = described_class.start(scope: @scope, run_id: queued.run_id)
    assert_equal "running", running.status
    assert running.started_at

    retrying = described_class.retrying(scope: @scope, run_id: queued.run_id)
    assert_equal "running", retrying.status
    assert_nil described_class.retrying(scope: @scope, run_id: "superseded")

    succeeded = described_class.succeed(scope: @scope, run_id: queued.run_id)
    assert_equal "succeeded", succeeded.status
    assert_equal "1/1", succeeded.progress_label
  end

  test "does not let a superseded run change the current generation" do
    old = described_class.enqueue(scope: @scope)
    current = described_class.enqueue(scope: @scope)

    assert_nil described_class.start(scope: @scope, run_id: old.run_id)
    assert_equal "queued", RefreshStatus::State.read(@scope).status
    assert_predicate described_class.start(scope: @scope, run_id: current.run_id), :running?
    assert_nil described_class.succeed(scope: @scope, run_id: old.run_id)
    assert_equal "running", RefreshStatus::State.read(@scope).status
  end

  test "records a failure and broadcasts the page update" do
    queued = described_class.enqueue(scope: @scope)
    described_class.start(scope: @scope, run_id: queued.run_id)
    calls = []
    error = RuntimeError.new("provider down")

    with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*args, **kwargs) { calls << [ args, kwargs ] }) do
      failed = described_class.fail(scope: @scope, run_id: queued.run_id, error:)
      described_class.broadcast(scope: @scope, refresh_path: "/corporate-action-imports")

      assert_equal "failed", failed.status
      assert_equal "RuntimeError", failed.error_class
      assert_equal "provider down", failed.error_message
    end

    args, kwargs = calls.sole
    assert_equal [ described_class.stream_name(@scope) ], args
    assert_equal described_class::TARGET, kwargs.fetch(:target)
    assert_equal "corporate_action_imports/scan_status", kwargs.fetch(:partial)
    assert_equal false, kwargs.fetch(:locals).fetch(:reload)
  end

  test "ignores broadcasts for unknown scopes" do
    assert_nil described_class.broadcast(scope: "unknown", refresh_path: "/corporate-action-imports")
    assert_nil described_class.fail(scope: "unknown", run_id: "missing", error: RuntimeError.new("missing"))
  end

  private

  def described_class
    CorporateActionImports::ScanStatus
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end
end
