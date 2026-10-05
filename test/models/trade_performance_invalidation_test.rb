require "test_helper"

class TradePerformanceInvalidationTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    CorporateActionImportScan.delete_all
    @user = users(:owner)
    @trade = trades(:owner_voo_buy)
    @state = PortfolioPerformanceMaterialization.for(user: @user)
  end

  test "creation durably records its date before enqueueing" do
    trade = @trade.dup
    trade.traded_on = Date.new(2026, 7, 1)
    trade.save!

    assert_equal trade.traded_on, @state.reload.requested_from
    assert_equal 1, @state.source_generation
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
    assert_enqueued_jobs 2, only: BuildInstrumentPerformanceObservationsJob
  end

  test "moving a date earlier or later invalidates the earliest affected date" do
    original_date = @trade.traded_on
    @trade.update!(traded_on: original_date + 2.days)
    assert_equal original_date, @state.reload.requested_from

    @trade.update!(traded_on: original_date - 2.days)
    assert_equal original_date - 2.days, @state.reload.requested_from
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
  end

  test "reassignment invalidates both owners" do
    other_user = users(:one)
    @trade.update!(user: other_user, institution: nil)

    [ @user, other_user ].each do |user|
      state = PortfolioPerformanceMaterialization.for(user:)
      assert_equal @trade.traded_on, state.requested_from
      assert_equal 1, state.source_generation
    end
    assert_enqueued_jobs 2, only: BuildPortfolioPerformanceObservationsJob
    assert_enqueued_jobs 4, only: BuildInstrumentPerformanceObservationsJob
  end

  test "moving instruments invalidates old and new targets from the earliest date" do
    original_instrument = @trade.instrument
    new_instrument = instruments(:petr4_bvmf)
    original_date = @trade.traded_on
    @trade.update!(instrument: new_instrument, currency: new_instrument.currency)

    [ original_instrument, new_instrument ].each do |instrument|
      currencies = [ instrument.currency, @user.reporting_currency ].uniq
      states = @user.instrument_performance_materializations.where(
        instrument:, reporting_currency: currencies
      )
      assert_equal currencies.sort, states.pluck(:reporting_currency).sort
      assert states.all? { |state| state.requested_from == original_date && state.source_generation == 1 }
    end
    assert_equal original_date, @state.reload.requested_from
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
    assert_enqueued_jobs 3, only: BuildInstrumentPerformanceObservationsJob
  end

  test "source edits invalidate previously used reporting currencies as well" do
    alternate = PortfolioPerformanceMaterialization.for(user: @user, reporting_currency: "USD")

    @trade.update!(quantity: "3")

    assert_equal 1, @state.reload.source_generation
    assert_equal 1, alternate.reload.source_generation
    assert_equal @trade.traded_on, alternate.requested_from
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
  end

  test "a new traded instrument schedules its provider scan" do
    calls = []
    original = CorporateActionImports::Automation.method(:call)
    CorporateActionImports::Automation.define_singleton_method(:call) do |**arguments|
      calls << arguments
      CorporateActionImports::Automation::Result.new(scheduled_count: 1, skipped_count: 0, failed_count: 0)
    end

    trade = @trade.dup
    trade.slug = nil
    trade.traded_on = Date.new(2026, 9, 1)
    trade.save!

    assert_equal [ @user, @trade.instrument ], [ calls.sole.fetch(:user), calls.sole.fetch(:instrument) ]
    assert_equal Date.current, calls.sole.fetch(:today)
  ensure
    CorporateActionImports::Automation.define_singleton_method(:call, original) if original
  end

  test "a trade date change rewinds and reschedules the instrument scan" do
    today = Date.current
    scan = CorporateActionImportScan.for(
      user: @user, instrument: @trade.instrument, source: CorporateActionImports::Automation::SOURCE
    )
    request = scan.claim!(from: @trade.traded_on, to: today)
    scan.start!(request.run_id)
    scan.complete!(request.run_id, through: today)
    calls = []
    original = CorporateActionImports::Automation.method(:call)
    CorporateActionImports::Automation.define_singleton_method(:call) do |**arguments|
      calls << arguments
      CorporateActionImports::Automation::Result.new(scheduled_count: 1, skipped_count: 0, failed_count: 0)
    end

    moved_on = @trade.traded_on - 2.days
    @trade.update!(traded_on: moved_on)

    assert_predicate scan.reload, :pending?
    assert_equal moved_on - 1.day, scan.scanned_through
    assert_equal [ @user, @trade.instrument ], [ calls.sole.fetch(:user), calls.sole.fetch(:instrument) ]
  ensure
    CorporateActionImports::Automation.define_singleton_method(:call, original) if original
  end

  test "a trade date change supersedes an active provider scan" do
    today = Date.current
    scan = CorporateActionImportScan.for(
      user: @user, instrument: @trade.instrument, source: CorporateActionImports::Automation::SOURCE
    )
    request = scan.claim!(from: @trade.traded_on, to: today)
    scan.start!(request.run_id)
    original_enqueue = ScanCorporateActionImportsJob.method(:perform_later)
    ScanCorporateActionImportsJob.define_singleton_method(:perform_later) { |**| Object.new }
    @trade.update!(traded_on: @trade.traded_on - 2.days)

    assert_predicate scan.reload, :queued?
    refute_equal request.run_id, scan.run_id
    assert_equal @trade.traded_on, scan.requested_from
  ensure
    ScanCorporateActionImportsJob.define_singleton_method(:perform_later, original_enqueue) if original_enqueue
  end

  test "position quantity and side edits rewind the instrument scan" do
    today = Date.current
    scan = CorporateActionImportScan.for(
      user: @user, instrument: @trade.instrument, source: CorporateActionImports::Automation::SOURCE
    )
    request = scan.claim!(from: @trade.traded_on, to: today)
    scan.start!(request.run_id)
    scan.complete!(request.run_id, through: today)
    original = CorporateActionImports::Automation.method(:call)
    CorporateActionImports::Automation.define_singleton_method(:call) do |**|
      CorporateActionImports::Automation::Result.new(scheduled_count: 1, skipped_count: 0, failed_count: 0)
    end

    @trade.update!(quantity: "3")
    assert_predicate scan.reload, :pending?

    request = scan.claim!(from: @trade.traded_on, to: today)
    scan.start!(request.run_id)
    scan.complete!(request.run_id, through: today)
    @trade.update!(side: :sell)

    assert_predicate scan.reload, :pending?
  ensure
    CorporateActionImports::Automation.define_singleton_method(:call, original) if original
  end

  test "notes edits do not schedule a provider scan" do
    calls = 0
    original = CorporateActionImports::Automation.method(:call)
    CorporateActionImports::Automation.define_singleton_method(:call) { |**| calls += 1 }

    @trade.update!(notes: "Only explanatory text changed")

    assert_equal 0, calls
  ensure
    CorporateActionImports::Automation.define_singleton_method(:call, original) if original
  end

  test "reports a handled provider scan enqueue failure" do
    failure = RuntimeError.new("scan unavailable")
    original_automation = CorporateActionImports::Automation.method(:call)
    reporter = Rails.error
    original_report = reporter.method(:report)
    reported = nil
    CorporateActionImports::Automation.define_singleton_method(:call) { |**| raise failure }
    reporter.define_singleton_method(:report) { |error, **context| reported = [ error, context ] }

    @trade.send(:enqueue_corporate_action_scan)

    assert_equal failure, reported.first
    assert_equal({ handled: true, context: { trade_id: @trade.id, source: "corporate_action_scan" } }, reported.second)
  ensure
    CorporateActionImports::Automation.define_singleton_method(:call, original_automation)
    reporter.define_singleton_method(:report, original_report)
  end

  test "skips a corporate action target when its records were removed" do
    original_targets = @trade.method(:corporate_action_scan_targets)
    @trade.define_singleton_method(:corporate_action_scan_targets) { { [ -1, -1 ] => Date.current } }

    assert_nothing_raised { @trade.send(:enqueue_corporate_action_scan) }
  ensure
    @trade.define_singleton_method(:corporate_action_scan_targets, original_targets) if original_targets
  end

  test "deleting the last trade queues a cleanup that cannot recreate its history" do
    @trade.destroy!

    perform_enqueued_jobs(only: BuildPortfolioPerformanceObservationsJob)

    assert_empty @user.portfolio_performance_observations
    assert_not_predicate @state.reload, :pending?
  end

  test "a later notes edit on the same instance does not reuse old invalidation targets" do
    @trade.update!(quantity: "3")
    generation = @state.reload.source_generation
    clear_enqueued_jobs
    Rails.cache.clear

    @trade.update!(notes: "Only explanatory text changed")

    assert_equal generation, @state.reload.source_generation
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  end

  test "source and durable invalidation roll back together when marking fails" do
    original_quantity = @trade.quantity
    original = Performance::ObservationInvalidator.method(:mark!)
    Performance::ObservationInvalidator.define_singleton_method(:mark!, lambda { |**arguments|
      original.call(**arguments)
      raise "invalidation unavailable"
    })

    assert_raises(RuntimeError) { @trade.update!(quantity: "9") }

    assert_equal original_quantity, @trade.reload.quantity
    assert_equal 0, @state.reload.source_generation
    assert_not_predicate @state, :pending?
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  ensure
    Performance::ObservationInvalidator.define_singleton_method(:mark!, original)
  end

  test "bulk trade creation coalesces into one earliest rebuild request" do
    dates = (Date.new(2026, 8, 14)..Date.new(2026, 9, 1)).to_a
    Trade.transaction do
      dates.each do |date|
        @trade.dup.tap { |trade| trade.traded_on = date }.save!
      end
    end

    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
    assert_equal dates.first, @state.reload.requested_from
    assert_equal dates.length, @state.source_generation
  end

  test "skips instrument invalidation targets whose source records no longer exist" do
    yielded = []
    targets = {
      [ -1, @trade.instrument_id ] => @trade.traded_on,
      [ @user.id, -1 ] => @trade.traded_on
    }

    @trade.send(:each_instrument_performance_target, targets) do |user, instrument, from|
      yielded << [ user, instrument, from ]
    end

    assert_empty yielded
  end
end
