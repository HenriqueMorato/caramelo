require "test_helper"

class CorporateActionImports::StaleScanRecoveryTest < ActiveJob::TestCase
  QueueActivityStub = Struct.new(:active, :arguments) do
    def active_job?(**)
      yield(arguments || {}) if block_given?
      active
    end
  end

  setup do
    Rails.cache.clear
    clear_enqueued_jobs
    CorporateActionImportScan.delete_all
    @user = users(:owner)
    @instrument = instruments(:voo_arcx)
    @today = Date.new(2026, 9, 30)
    @scan = CorporateActionImportScan.for(user: @user, instrument: @instrument)
  end

  test "reclaims an orphaned scan and schedules a replacement" do
    request = @scan.claim!(from: @user.trades.where(instrument: @instrument).minimum(:traded_on), to: @today)
    @scan.start!(request.run_id)
    @scan.update_columns(started_at: 6.minutes.ago, updated_at: 6.minutes.ago)

    result = recover(scan_scope: [ @scan ])

    assert_equal 1, result.recovered_count
    assert result.changed?
    assert_predicate @scan.reload, :queued?
    refute_equal request.run_id, @scan.run_id
    assert_enqueued_jobs 1, only: ScanCorporateActionImportsJob
  end

  test "does not reclaim a stale scan while its queue job is active" do
    request = @scan.claim!(from: @user.trades.where(instrument: @instrument).minimum(:traded_on), to: @today)
    @scan.start!(request.run_id)
    @scan.update_columns(started_at: 6.minutes.ago, updated_at: 6.minutes.ago)

    result = recover(queue_activity: QueueActivityStub.new(true), scan_scope: [ @scan ])

    assert_equal 0, result.recovered_count
    assert_equal request.run_id, @scan.reload.run_id
    assert_empty enqueued_jobs
  end

  test "ignores a fresh active scan" do
    request = @scan.claim!(from: @user.trades.where(instrument: @instrument).minimum(:traded_on), to: @today)
    @scan.start!(request.run_id)

    result = recover(scan_scope: [ @scan ])

    assert_equal 0, result.recovered_count
    assert_equal request.run_id, @scan.reload.run_id
    assert_empty enqueued_jobs
  end

  test "does not count a scan when automation skips it" do
    request = @scan.claim!(from: @user.trades.where(instrument: @instrument).minimum(:traded_on), to: @today)
    @scan.start!(request.run_id)
    @scan.update_columns(started_at: 6.minutes.ago, updated_at: 6.minutes.ago)
    with_stubbed_method(
      CorporateActionImports::Automation, :call,
      ->(**) { CorporateActionImports::Automation::Result.new(scheduled_count: 0, skipped_count: 1, failed_count: 0) }
    ) do
      result = recover(scan_scope: [ @scan ])

      assert_equal 0, result.recovered_count
      assert_equal request.run_id, @scan.reload.run_id
      assert_empty enqueued_jobs
    end
  end

  test "counts a durable automation failure as a changed scan" do
    request = @scan.claim!(from: @user.trades.where(instrument: @instrument).minimum(:traded_on), to: @today)
    @scan.start!(request.run_id)
    @scan.update_columns(started_at: 6.minutes.ago, updated_at: 6.minutes.ago)
    failure = CorporateActionImports::Automation::Result.new(scheduled_count: 0, skipped_count: 0, failed_count: 1)

    with_stubbed_method(CorporateActionImports::Automation, :call, ->(**) { failure }) do
      result = recover(scan_scope: [ @scan ])

      assert_equal 0, result.recovered_count
      assert_equal 1, result.changed_count
    end
  end

  test "reports a replacement enqueue error without stopping the sweep" do
    request = @scan.claim!(from: @user.trades.where(instrument: @instrument).minimum(:traded_on), to: @today)
    @scan.start!(request.run_id)
    @scan.update_columns(started_at: 6.minutes.ago, updated_at: 6.minutes.ago)
    reported = []

    with_stubbed_method(CorporateActionImports::Automation, :call, ->(**) { raise "queue unavailable" }) do
      with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
        result = recover(scan_scope: [ @scan ])

        assert_equal 0, result.recovered_count
      end
    end

    assert_equal "queue unavailable", reported.sole.message
  end

  test "reports a malformed scan without an identifier" do
    reported = []

    with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
      result = CorporateActionImports::StaleScanRecovery.call(
        scan_scope: [ nil ], queue_activity: QueueActivityStub.new(false)
      )

      assert_equal 0, result.recovered_count
      assert_includes reported.sole.message, "active_expired?"
    end
  end

  private

  def recover(queue_activity: QueueActivityStub.new(
    false, { automation_scan_id: @scan.id, automation_run_id: @scan.run_id }
  ), scan_scope: nil)
    CorporateActionImports::StaleScanRecovery.call(queue_activity:, scan_scope:)
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
