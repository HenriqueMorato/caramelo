require "test_helper"

class ScanCorporateActionImportsJobTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
  end

  test "uses a separate concurrency key for each instrument target" do
    key = ScanCorporateActionImportsJob.concurrency_key.call(
      user_id: users(:owner).id, source: "yahoo_finance", instrument_id: instruments(:voo_arcx).id
    )

    assert_equal "corporate-action-imports:#{users(:owner).id}:yahoo_finance:#{instruments(:voo_arcx).id}", key
    assert_equal "corporate-action-imports:1:yahoo_finance:all", ScanCorporateActionImportsJob.concurrency_key.call(
      user_id: 1, source: "yahoo_finance", instrument_id: nil
    )
  end

  test "delegates a bounded scan to the idempotent import service" do
    result = Object.new
    received = nil
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) do |**arguments|
      received = arguments
      result
    end

    returned = ScanCorporateActionImportsJob.perform_now(
      user_id: users(:owner).id, from: "2026-08-01", to: "2026-08-31",
      source: "yahoo_finance", instrument_id: instruments(:voo_arcx).id
    )

    assert_same result, returned
    assert_equal users(:owner), received.fetch(:user)
    assert_equal instruments(:voo_arcx), received.fetch(:instrument)
    assert received.fetch(:strict)
    assert_equal Date.new(2026, 8, 1), received.fetch(:from)
    assert_equal Date.new(2026, 8, 31), received.fetch(:to)
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end

  test "does not turn an invalid instrument target into an owner-wide scan" do
    assert_raises(ActiveRecord::RecordNotFound) do
      ScanCorporateActionImportsJob.perform_now(
        user_id: users(:owner).id, from: "2026-08-01", to: "2026-08-31",
        source: "yahoo_finance", instrument_id: instruments(:petr4_bvmf).id
      )
    end
  end

  test "scans all traded instruments when no target is supplied" do
    result = Object.new
    received = nil
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) do |**arguments|
      received = arguments
      result
    end

    assert_same result, ScanCorporateActionImportsJob.perform_now(
      user_id: users(:owner).id, from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance"
    )
    assert_nil received.fetch(:instrument)
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end

  test "publishes a successful tracked scan only after the provider returns" do
    user = users(:owner)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: "yahoo_finance", instrument_id: instruments(:voo_arcx).id
    )
    queued = CorporateActionImports::ScanStatus.enqueue(scope:)
    result = Object.new
    instrument = instruments(:voo_arcx)
    test_case = self
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) do |**arguments|
      test_case.assert_equal instrument, arguments.fetch(:instrument)
      test_case.assert arguments.fetch(:strict)
      result
    end
    broadcasts = []
    original_broadcast = CorporateActionImports::ScanStatus.method(:broadcast)
    CorporateActionImports::ScanStatus.define_singleton_method(:broadcast) do |**arguments|
      broadcasts << arguments
    end

    returned = ScanCorporateActionImportsJob.perform_now(
      user_id: user.id, from: from.iso8601, to: to.iso8601, source: "yahoo_finance",
      instrument_id: instruments(:voo_arcx).id, scope:, scan_run_id: queued.run_id
    )

    assert_same result, returned
    assert_equal "succeeded", RefreshStatus::State.read(scope).status
    assert_equal [ true ], broadcasts.map { |call| call.fetch(:reload) }
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
    CorporateActionImports::ScanStatus.define_singleton_method(:broadcast, original_broadcast)
  end

  test "skips a worker from a superseded scan generation" do
    user = users(:owner)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: "yahoo_finance", instrument_id: nil
    )
    old = CorporateActionImports::ScanStatus.enqueue(scope:)
    CorporateActionImports::ScanStatus.enqueue(scope:)
    calls = 0
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| calls += 1 }

    assert_nil ScanCorporateActionImportsJob.perform_now(
      user_id: user.id, from: from.iso8601, to: to.iso8601, source: "yahoo_finance",
      scope:, scan_run_id: old.run_id
    )
    assert_equal 0, calls
    assert_equal "queued", RefreshStatus::State.read(scope).status
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end

  test "keeps a retryable provider error active until retries are exhausted" do
    user = users(:owner)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: "yahoo_finance", instrument_id: nil
    )
    queued = CorporateActionImports::ScanStatus.enqueue(scope:)
    error = MarketData::YahooFinance::ProviderUnavailable.new(status: 503)
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| raise error }

    assert_raises(MarketData::YahooFinance::ProviderUnavailable) do
      ScanCorporateActionImportsJob.new.perform(
        user_id: user.id, from: from.iso8601, to: to.iso8601, source: "yahoo_finance",
        scope:, scan_run_id: queued.run_id
      )
    end

    assert_equal "running", RefreshStatus::State.read(scope).status
    job = ScanCorporateActionImportsJob.new
    job.instance_variable_set(:@scan_scope, scope)
    job.instance_variable_set(:@scan_run_id, queued.run_id)
    job.instance_variable_set(:@scan_refresh_path, "/corporate-action-imports")
    job.mark_scan_failed(error)
    assert_equal "failed", RefreshStatus::State.read(scope).status
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end

  test "marks terminal provider errors as failed" do
    user = users(:owner)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: "yahoo_finance", instrument_id: nil
    )
    queued = CorporateActionImports::ScanStatus.enqueue(scope:)
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| raise ArgumentError, "bad request" }

    assert_raises(ArgumentError) do
      ScanCorporateActionImportsJob.new.perform(
        user_id: user.id, from: from.iso8601, to: to.iso8601, source: "yahoo_finance",
        scope:, scan_run_id: queued.run_id
      )
    end

    assert_equal "failed", RefreshStatus::State.read(scope).status
    assert_equal "bad request", RefreshStatus::State.read(scope).error_message
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end

  test "marks a retryable scan failed when Active Job exhausts retries" do
    user = users(:owner)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: "yahoo_finance", instrument_id: nil
    )
    queued = CorporateActionImports::ScanStatus.enqueue(scope:)
    error = MarketData::YahooFinance::ProviderUnavailable.new(status: 503)
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| raise error }
    job = ScanCorporateActionImportsJob.new
    job.arguments = [ Hash.ruby2_keywords_hash(
      user_id: user.id, from: from.iso8601, to: to.iso8601, source: "yahoo_finance",
      scope:, scan_run_id: queued.run_id
    ) ]
    job.exception_executions[
      [ MarketData::YahooFinance::TransportError, MarketData::YahooFinance::RateLimited,
        MarketData::YahooFinance::ProviderUnavailable ].to_s
    ] = ScanCorporateActionImportsJob::RETRY_ATTEMPTS - 1

    job.perform_now

    assert_equal "failed", RefreshStatus::State.read(scope).status
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end

  test "rejects a worker whose scope does not match its arguments" do
    actual_scope = CorporateActionImports::ScanStatus.scope(
      user: users(:owner), from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31),
      source: "yahoo_finance", instrument_id: nil
    )
    queued = CorporateActionImports::ScanStatus.enqueue(scope: actual_scope)

    assert_raises(ArgumentError) do
      ScanCorporateActionImportsJob.new.perform(
        user_id: users(:owner).id, from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance",
        scope: "wrong-scope", scan_run_id: queued.run_id
      )
    end
  end

  test "does nothing when a terminal callback has no current scan" do
    assert_nil ScanCorporateActionImportsJob.new.mark_scan_failed(RuntimeError.new("missing"))
  end
end
