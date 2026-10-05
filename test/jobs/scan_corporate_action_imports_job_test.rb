require "test_helper"

class ScanCorporateActionImportsJobTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    CorporateActionImportScan.delete_all
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
    CorporateActionImports::Scan.define_singleton_method(:call, original) if original
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
    CorporateActionImports::Scan.define_singleton_method(:call, original) if original
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

  test "advances the durable automation watermark after a successful provider scan" do
    original_scan = CorporateActionImports::Scan.method(:call)
    original_broadcast = MarketData::HealthReportBroadcaster.method(:refresh)
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id
    )
    CorporateActionImports::ScanStatus.enqueue(scope:, run_id: request.run_id)
    result = Object.new
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| result }
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh) { }

    returned = ScanCorporateActionImportsJob.perform_now(
      user_id: user.id, from: from.iso8601, to: to.iso8601,
      source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
      scope:, scan_run_id: request.run_id, automation_scan_id: scan.id, automation_run_id: request.run_id
    )

    assert_same result, returned
    assert_predicate scan.reload, :succeeded?
    assert_equal to, scan.scanned_through
    assert_nil scan.requested_range
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original_scan) if original_scan
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh, original_broadcast) if original_broadcast
  end

  test "fails the durable automation state on a terminal provider error" do
    original_scan = CorporateActionImports::Scan.method(:call)
    original_broadcast = MarketData::HealthReportBroadcaster.method(:refresh)
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id
    )
    CorporateActionImports::ScanStatus.enqueue(scope:, run_id: request.run_id)
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| raise ArgumentError, "invalid provider response" }
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh) { }

    assert_raises(ArgumentError) do
      ScanCorporateActionImportsJob.perform_now(
        user_id: user.id, from: from.iso8601, to: to.iso8601,
        source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
        scope:, scan_run_id: request.run_id, automation_scan_id: scan.id, automation_run_id: request.run_id
      )
    end

    assert_predicate scan.reload, :failed?
    assert_equal "invalid provider response", scan.failure_message
    assert_nil scan.scanned_through
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original_scan) if original_scan
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh, original_broadcast) if original_broadcast
  end

  test "does not publish health when automation start is superseded" do
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    original_start = scan.method(:start!)
    original_find = CorporateActionImportScan.method(:find)
    scan.define_singleton_method(:start!) { |_run_id| false }
    CorporateActionImportScan.define_singleton_method(:find) { |_id| scan }

    assert_nil ScanCorporateActionImportsJob.perform_now(
      user_id: user.id, from: from.iso8601, to: to.iso8601,
      source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
      automation_scan_id: scan.id, automation_run_id: request.run_id
    )
  ensure
    scan.define_singleton_method(:start!, original_start) if scan && original_start
    CorporateActionImportScan.define_singleton_method(:find, original_find) if original_find
  end

  test "does not broadcast health when automation completion is superseded" do
    original_scan = CorporateActionImports::Scan.method(:call)
    original_broadcast = MarketData::HealthReportBroadcaster.method(:refresh)
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    original_complete = scan.method(:complete!)
    original_find = CorporateActionImportScan.method(:find)
    scan.define_singleton_method(:complete!) { |_run_id, through:| false }
    CorporateActionImportScan.define_singleton_method(:find) { |_id| scan }
    broadcasts = 0
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| Object.new }
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh) { broadcasts += 1 }

    ScanCorporateActionImportsJob.perform_now(
      user_id: user.id, from: from.iso8601, to: to.iso8601,
      source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
      automation_scan_id: scan.id, automation_run_id: request.run_id
    )

    assert_equal 0, broadcasts
  ensure
    scan.define_singleton_method(:complete!, original_complete) if scan && original_complete
    CorporateActionImportScan.define_singleton_method(:find, original_find) if original_find
    CorporateActionImports::Scan.define_singleton_method(:call, original_scan) if original_scan
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh, original_broadcast) if original_broadcast
  end

  test "does not broadcast health when automation failure is superseded" do
    original_scan = CorporateActionImports::Scan.method(:call)
    original_broadcast = MarketData::HealthReportBroadcaster.method(:refresh)
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    original_fail = scan.method(:fail!)
    original_find = CorporateActionImportScan.method(:find)
    scan.define_singleton_method(:fail!) { |_run_id, error:| false }
    CorporateActionImportScan.define_singleton_method(:find) { |_id| scan }
    broadcasts = 0
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| raise ArgumentError, "bad provider response" }
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh) { broadcasts += 1 }

    assert_raises(ArgumentError) do
      ScanCorporateActionImportsJob.perform_now(
        user_id: user.id, from: from.iso8601, to: to.iso8601,
        source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
        automation_scan_id: scan.id, automation_run_id: request.run_id
      )
    end

    assert_equal 0, broadcasts
  ensure
    scan.define_singleton_method(:fail!, original_fail) if scan && original_fail
    CorporateActionImportScan.define_singleton_method(:find, original_find) if original_find
    CorporateActionImports::Scan.define_singleton_method(:call, original_scan) if original_scan
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh, original_broadcast) if original_broadcast
  end

  test "fails the durable automation state when retries are exhausted" do
    original_scan = CorporateActionImports::Scan.method(:call)
    original_broadcast = MarketData::HealthReportBroadcaster.method(:refresh)
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id
    )
    CorporateActionImports::ScanStatus.enqueue(scope:, run_id: request.run_id)
    error = MarketData::YahooFinance::ProviderUnavailable.new(status: 503)
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| raise error }
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh) { }
    job = ScanCorporateActionImportsJob.new
    job.arguments = [ Hash.ruby2_keywords_hash(
      user_id: user.id, from: from.iso8601, to: to.iso8601,
      source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
      scope:, scan_run_id: request.run_id, automation_scan_id: scan.id, automation_run_id: request.run_id
    ) ]
    job.exception_executions[
      [ MarketData::YahooFinance::TransportError, MarketData::YahooFinance::RateLimited,
        MarketData::YahooFinance::ProviderUnavailable ].to_s
    ] = ScanCorporateActionImportsJob::RETRY_ATTEMPTS - 1

    job.perform_now

    assert_predicate scan.reload, :failed?
    assert_equal error.message, scan.failure_message
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original_scan) if original_scan
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh, original_broadcast) if original_broadcast
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

  test "does not let a superseded automation worker overwrite the current status" do
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    old_request = scan.claim!(from:, to:)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id
    )
    CorporateActionImports::ScanStatus.enqueue(scope:, run_id: old_request.run_id)
    scan.update_columns(status: "pending", run_id: nil, requested_from: nil, requested_to: nil)
    new_request = scan.claim!(from:, to:)
    CorporateActionImports::ScanStatus.enqueue(scope:, run_id: new_request.run_id)
    calls = 0
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| calls += 1 }

    assert_nil ScanCorporateActionImportsJob.perform_now(
      user_id: user.id, from: from.iso8601, to: to.iso8601,
      source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
      scope:, scan_run_id: old_request.run_id, automation_scan_id: scan.id, automation_run_id: old_request.run_id
    )
    assert_equal 0, calls
    assert_equal new_request.run_id, RefreshStatus::State.read(scope).run_id
    assert_equal "queued", RefreshStatus::State.read(scope).status
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original) if original
  end

  test "ignores a provider result that supersedes the automation generation" do
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id
    )
    CorporateActionImports::ScanStatus.enqueue(scope:, run_id: request.run_id)
    original_scan = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) do |**|
      raise CorporateActionImports::Scan::Superseded, "corporate-action scan generation was superseded"
    end

    assert_nil ScanCorporateActionImportsJob.perform_now(
      user_id: user.id, from: from.iso8601, to: to.iso8601,
      source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
      scope:, scan_run_id: request.run_id, automation_scan_id: scan.id, automation_run_id: request.run_id
    )
    assert_predicate scan.reload, :running?
    assert_equal "failed", RefreshStatus::State.read(scope).status
    assert_includes RefreshStatus::State.read(scope).error_message, "superseded"
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original_scan) if original_scan
  end

  test "ignores a superseded automation result without transient scan status" do
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    original_scan = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) do |**|
      raise CorporateActionImports::Scan::Superseded, "corporate-action scan generation was superseded"
    end

    assert_nil ScanCorporateActionImportsJob.perform_now(
      user_id: user.id, from: from.iso8601, to: to.iso8601,
      source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
      automation_scan_id: scan.id, automation_run_id: request.run_id
    )
    assert_predicate scan.reload, :running?
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original_scan) if original_scan
  end

  test "rejects an automation job whose target no longer matches its durable state" do
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    scope = CorporateActionImports::ScanStatus.scope(
      user: users(:one), from:, to:, source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id
    )
    CorporateActionImports::ScanStatus.enqueue(scope:, run_id: request.run_id)

    assert_raises(ArgumentError) do
      ScanCorporateActionImportsJob.perform_now(
        user_id: users(:one).id, from: from.iso8601, to: to.iso8601,
        source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
        scope:, scan_run_id: request.run_id, automation_scan_id: scan.id, automation_run_id: request.run_id
      )
    end

    assert_predicate scan.reload, :failed?
    assert_equal 0, CorporateActionImport.where(user:, instrument:).count
  end

  test "rejects an automation job without a requested range" do
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)

    assert_raises(ArgumentError) do
      ScanCorporateActionImportsJob.perform_now(
        user_id: user.id, from: "2026-08-01", to: "2026-08-31",
        source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
        automation_scan_id: scan.id, automation_run_id: SecureRandom.uuid
      )
    end
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

  test "ignores malformed automation callback arguments" do
    job = ScanCorporateActionImportsJob.new
    job.arguments = [ { automation_scan_id: 1, automation_run_id: nil } ]

    assert_nil job.mark_scan_failed(RuntimeError.new("missing"))
  end

  test "keeps durable completion when the health broadcast fails" do
    user = users(:owner)
    instrument = instruments(:voo_arcx)
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scan = CorporateActionImportScan.create!(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    request = scan.claim!(from:, to:)
    scope = CorporateActionImports::ScanStatus.scope(
      user:, from:, to:, source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id
    )
    CorporateActionImports::ScanStatus.enqueue(scope:, run_id: request.run_id)
    original_scan = CorporateActionImports::Scan.method(:call)
    original_broadcast = MarketData::HealthReportBroadcaster.method(:refresh)
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| Object.new }
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh) { raise "broadcast unavailable" }

    ScanCorporateActionImportsJob.perform_now(
      user_id: user.id, from: from.iso8601, to: to.iso8601,
      source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: instrument.id,
      scope:, scan_run_id: request.run_id, automation_scan_id: scan.id, automation_run_id: request.run_id
    )

    assert_predicate scan.reload, :succeeded?
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original_scan) if original_scan
    MarketData::HealthReportBroadcaster.define_singleton_method(:refresh, original_broadcast) if original_broadcast
  end
end
