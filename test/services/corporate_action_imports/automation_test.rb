require "test_helper"

class CorporateActionImports::AutomationTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    CorporateActionImportScan.delete_all
    clear_enqueued_jobs
    @user = users(:owner)
    @instrument = instruments(:voo_arcx)
    @today = Date.new(2026, 9, 30)
  end

  test "schedules the first-trade-through-today scan for each traded instrument" do
    captured = []
    with_stubbed_method(ScanCorporateActionImportsJob, :perform_later, ->(**arguments) { captured << arguments; Object.new }) do
      result = CorporateActionImports::Automation.call(user: @user, today: @today)

      assert_equal 1, result.scheduled_count
    end

    scan = CorporateActionImportScan.find_by!(user: @user, instrument: @instrument)
    assert_equal @user.trades.where(instrument: @instrument).minimum(:traded_on), scan.requested_from
    assert_equal @today, scan.requested_to
    assert_predicate scan, :queued?
    assert_equal @instrument.id, captured.sole.fetch(:instrument_id)
    assert_equal scan.run_id, captured.sole.fetch(:automation_run_id)
  end

  test "rejects an unsupported provider source" do
    assert_raises(ArgumentError) do
      CorporateActionImports::Automation.call(user: @user, source: "unsupported", today: @today)
    end
  end

  test "coalesces an overlapping scheduler run and resumes from the watermark" do
    with_stubbed_method(ScanCorporateActionImportsJob, :perform_later, ->(**) { Object.new }) do
      first = CorporateActionImports::Automation.call(user: @user, today: @today)
      second = CorporateActionImports::Automation.call(user: @user, today: @today)
      assert_equal 1, first.scheduled_count
      assert_equal 1, second.skipped_count
    end

    scan = CorporateActionImportScan.find_by!(user: @user, instrument: @instrument)
    run_id = scan.run_id
    scan.start!(run_id)
    scan.complete!(run_id, through: @today)

    next_day = @today + 1.day
    with_stubbed_method(ScanCorporateActionImportsJob, :perform_later, ->(**) { Object.new }) do
      result = CorporateActionImports::Automation.call(user: @user, today: next_day)
      assert_equal 1, result.scheduled_count
    end
    assert_equal @today, scan.reload.requested_from
    assert_equal next_day, scan.requested_to
  end

  test "reclaims an abandoned active scan after its lease expires" do
    scan = CorporateActionImportScan.for(user: @user, instrument: @instrument)
    old_request = scan.claim!(from: @user.trades.where(instrument: @instrument).minimum(:traded_on), to: @today)
    scan.start!(old_request.run_id)
    scan.update_columns(started_at: 2.days.ago, updated_at: 2.days.ago)

    captured = []
    with_stubbed_method(ScanCorporateActionImportsJob, :perform_later, ->(**arguments) { captured << arguments; Object.new }) do
      result = CorporateActionImports::Automation.call(user: @user, instrument: @instrument, today: @today)

      assert_equal 1, result.scheduled_count
    end

    assert_predicate scan.reload, :queued?
    refute_equal old_request.run_id, scan.run_id
    assert_equal scan.run_id, captured.sole.fetch(:automation_run_id)
  end

  test "continues from the watermark after an unrelated trade update" do
    with_stubbed_method(ScanCorporateActionImportsJob, :perform_later, ->(**) { Object.new }) do
      first = CorporateActionImports::Automation.call(user: @user, instrument: @instrument, today: @today)
      assert_equal 1, first.scheduled_count
    end

    scan = CorporateActionImportScan.find_by!(user: @user, instrument: @instrument)
    run_id = scan.run_id
    scan.start!(run_id)
    scan.complete!(run_id, through: @today)
    @user.trades.where(instrument: @instrument).update_all(updated_at: Time.current + 1.minute)

    with_stubbed_method(ScanCorporateActionImportsJob, :perform_later, ->(**) { Object.new }) do
      result = CorporateActionImports::Automation.call(user: @user, instrument: @instrument, today: @today + 1.day)

      assert_equal 1, result.scheduled_count
    end

    assert_equal @today, scan.reload.requested_from
  end

  test "skips a scan whose watermark is already ahead of today" do
    scan = CorporateActionImportScan.for(user: @user, instrument: @instrument)
    scan.update!(status: :succeeded, scanned_through: @today + 1.day, completed_at: Time.current)

    result = CorporateActionImports::Automation.call(user: @user, instrument: @instrument, today: @today)

    assert_equal 1, result.skipped_count
    assert_empty enqueued_jobs
  end

  test "does not create automation rows for an owner without trades" do
    owner = User.create!(email_address: "automation-empty@example.com", password: "password")

    result = CorporateActionImports::Automation.call(user: owner, today: @today)

    assert_equal 0, result.scheduled_count
    assert_empty owner.corporate_action_import_scans
    assert_empty enqueued_jobs
  end

  test "records an enqueue failure without losing the requested range" do
    with_stubbed_method(ScanCorporateActionImportsJob, :perform_later, ->(**) { nil }) do
      result = CorporateActionImports::Automation.call(user: @user, today: @today)

      assert_equal 0, result.scheduled_count
      assert_equal 1, result.failed_count
    end

    scan = CorporateActionImportScan.find_by!(user: @user, instrument: @instrument)
    assert_predicate scan, :failed?
    assert_includes scan.failure_message, "could not be enqueued"
    assert_equal @user.trades.where(instrument: @instrument).minimum(:traded_on), scan.requested_from
    assert_equal @today, scan.requested_to
  end

  test "records a failure before a scan status scope is available" do
    original_scope = CorporateActionImports::ScanStatus.method(:scope)
    CorporateActionImports::ScanStatus.define_singleton_method(:scope) { |**| raise "status unavailable" }

    with_stubbed_method(ScanCorporateActionImportsJob, :perform_later, ->(**) { Object.new }) do
      result = CorporateActionImports::Automation.call(user: @user, instrument: @instrument, today: @today)

      assert_equal 1, result.failed_count
    end
  ensure
    CorporateActionImports::ScanStatus.define_singleton_method(:scope, original_scope) if original_scope
  end

  test "records a failure when a scan claim cannot be acquired" do
    state = Object.new
    state.define_singleton_method(:scanned_through) { nil }
    state.define_singleton_method(:claim!) { |**| raise "claim unavailable" }
    original_for = CorporateActionImportScan.method(:for)
    CorporateActionImportScan.define_singleton_method(:for) { |**| state }

    result = CorporateActionImports::Automation.call(user: @user, instrument: @instrument, today: @today)

    assert_equal 1, result.failed_count
  ensure
    CorporateActionImportScan.define_singleton_method(:for, original_for) if original_for
  end

  test "does not publish transient status after a durable generation is superseded" do
    scan = CorporateActionImportScan.for(user: @user, instrument: @instrument)
    original_for = CorporateActionImportScan.method(:for)
    original_fence = scan.method(:with_current_run)
    CorporateActionImportScan.define_singleton_method(:for) { |**| scan }
    scan.define_singleton_method(:with_current_run) { |_run_id| false }

    result = CorporateActionImports::Automation.call(user: @user, instrument: @instrument, today: @today)

    assert_equal 1, result.skipped_count
    assert_empty enqueued_jobs
    assert_nil RefreshStatus::State.read(
      CorporateActionImports::ScanStatus.scope(
        user: @user, from: @user.trades.where(instrument: @instrument).minimum(:traded_on),
        to: @today, source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: @instrument.id
      )
    )
  ensure
    CorporateActionImportScan.define_singleton_method(:for, original_for) if original_for
    scan.define_singleton_method(:with_current_run, original_fence) if scan && original_fence
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
