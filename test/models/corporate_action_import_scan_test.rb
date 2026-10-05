require "test_helper"

class CorporateActionImportScanTest < ActiveSupport::TestCase
  setup do
    CorporateActionImportScan.delete_all
    @user = users(:owner)
    @instrument = instruments(:voo_arcx)
    @scan = CorporateActionImportScan.for(user: @user, instrument: @instrument)
    @from = Date.current - 4.days
    @to = Date.current - 1.day
  end

  test "keeps one normalized scan state per owner instrument and source" do
    assert_equal @scan, CorporateActionImportScan.for(
      user: @user, instrument: @instrument, source: " YAHOO_FINANCE "
    )
    assert_equal "yahoo_finance", @scan.source
    assert_equal "pending", @scan.status
  end

  test "claims a range once and fences the durable watermark" do
    request = @scan.claim!(from: @from, to: @to)

    assert_equal @scan.id, request.id
    assert_equal request.run_id, @scan.run_id
    assert_predicate @scan, :queued?
    assert_equal @from..@to, @scan.requested_range
    assert @scan.start!(request.run_id)
    assert @scan.complete!(request.run_id, through: @to)
    assert_equal @to, @scan.reload.scanned_through
    assert_not_predicate @scan, :active?
    assert_nil @scan.requested_range
    refute @scan.complete!(request.run_id, through: @to)
  end

  test "returns no requested range before a claim" do
    assert_nil @scan.requested_range
  end

  test "recognizes only old active work as expired" do
    request = @scan.claim!(from: @from, to: @to)

    refute @scan.active_expired?
    @scan.update_columns(updated_at: 2.days.ago)
    assert @scan.active_expired?
    @scan.start!(request.run_id)
    @scan.update_columns(started_at: 2.days.ago)
    assert @scan.active_expired?
  end

  test "rewinds its watermark and fences any active run" do
    request = @scan.claim!(from: @from, to: @to)
    @scan.start!(request.run_id)
    @scan.complete!(request.run_id, through: @to)

    assert @scan.rewind!(from: @from + 2.days)
    assert_predicate @scan.reload, :pending?
    assert_equal @from + 1.day, @scan.scanned_through
    assert_nil @scan.run_id
    assert_nil @scan.completed_at

    request = @scan.claim!(from: @from, to: @to)
    assert @scan.rewind!(from: @from + 1.day)
    assert_not @scan.current_run?(request.run_id)
    refute @scan.rewind!(from: @from + 1.day)
  end

  test "fences a block to the current run" do
    request = @scan.claim!(from: @from, to: @to)

    assert_equal :completed, @scan.with_current_run(request.run_id) { :completed }
    assert_equal false, @scan.with_current_run("superseded") { flunk "stale run executed" }
  end

  test "does not advance a superseded or failed run" do
    request = @scan.claim!(from: @from, to: @to)
    assert @scan.start!(request.run_id)
    assert @scan.fail!(request.run_id, error: RuntimeError.new("provider down"))
    assert_equal "provider down", @scan.reload.failure_message
    assert_nil @scan.scanned_through

    retry_request = @scan.claim!(from: @from, to: @to)
    refute @scan.complete!(request.run_id, through: @to)
    assert @scan.complete!(retry_request.run_id, through: @to)
    refute @scan.start!(request.run_id)
    refute @scan.fail!(request.run_id, error: RuntimeError.new("stale"))
  end

  test "database constraints protect uniqueness and requested ranges" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      CorporateActionImportScan.insert_all!([
        { user_id: @user.id, instrument_id: @instrument.id, source: "yahoo_finance",
          created_at: Time.current, updated_at: Time.current }
      ])
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      @scan.update_columns(requested_from: @to, requested_to: @from)
    end
  end

  test "validates complete requested ranges and past dates" do
    @scan.requested_from = @from
    @scan.requested_to = nil
    refute @scan.valid?
    assert_includes @scan.errors[:base], "requested range must include both boundaries"

    @scan.requested_from = @to
    @scan.requested_to = @from
    refute @scan.valid?
    assert_includes @scan.errors[:base], "requested range must be chronological"

    assert_raises(ArgumentError) do
      @scan.claim!(from: Date.current + 1.day, to: Date.current + 1.day)
    end
  end

  test "rejects sources outside the provider registry" do
    invalid = CorporateActionImportScan.new(user: @user, instrument: @instrument, source: "unknown")

    refute_predicate invalid, :valid?
    assert_includes invalid.errors[:source], "is not included in the list"

    assert_raises(ActiveRecord::StatementInvalid) do
      CorporateActionImportScan.insert_all!([
        { user_id: @user.id, instrument_id: @instrument.id, source: "unknown",
          created_at: Time.current, updated_at: Time.current }
      ])
    end
  end
end
