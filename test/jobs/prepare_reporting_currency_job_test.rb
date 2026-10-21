require "test_helper"

class PrepareReportingCurrencyJobTest < ActiveJob::TestCase
  test "enqueues the saved currency" do
    assert PrepareReportingCurrencyJob.enqueue_for(user: users(:owner))
    assert_enqueued_with(job: PrepareReportingCurrencyJob, args: ->(args) {
      args.first == users(:owner) && args.last[:currency] == "BRL" && args.last[:run_id].present?
    })
  end

  test "reports queue failure without discarding the preference" do
    original = PrepareReportingCurrencyJob.method(:perform_later)
    PrepareReportingCurrencyJob.define_singleton_method(:perform_later) { |*| raise ActiveJob::EnqueueError }

    assert_not PrepareReportingCurrencyJob.enqueue_for(user: users(:owner))
    assert_predicate RefreshStatus::State.read("reporting_currency:#{users(:owner).id}:BRL"), :failed?
  ensure
    PrepareReportingCurrencyJob.define_singleton_method(:perform_later, original)
  end

  test "marks the refresh failed when the queue returns no job" do
    original = PrepareReportingCurrencyJob.method(:perform_later)
    PrepareReportingCurrencyJob.define_singleton_method(:perform_later) { |*| nil }

    assert_not PrepareReportingCurrencyJob.enqueue_for(user: users(:owner))
    assert_predicate RefreshStatus::State.read("reporting_currency:#{users(:owner).id}:BRL"), :failed?
  ensure
    PrepareReportingCurrencyJob.define_singleton_method(:perform_later, original)
  end

  test "reports invalid currency before a refresh run is registered" do
    user = Struct.new(:id, :reporting_currency).new(42, "not-a-currency")
    reported = []

    with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
      assert_not PrepareReportingCurrencyJob.enqueue_for(user:)
    end

    assert_instance_of ArgumentError, reported.sole
  end

  test "claims a fresh run after an earlier preparation completed" do
    scope = "reporting_currency:#{users(:owner).id}:BRL"
    RefreshStatus::Tracker.enqueue(scope:, run_id: "old-run")

    assert PrepareReportingCurrencyJob.enqueue_for(user: users(:owner))

    state = RefreshStatus::State.read(scope)
    assert_equal "queued", state.status
    refute_equal "old-run", state.run_id
  end

  test "includes only stable arguments in the preparation concurrency key" do
    job = PrepareReportingCurrencyJob.new(users(:owner), currency: "EUR", run_id: "run-1")

    assert_equal "PrepareReportingCurrencyJob/reporting_currency:#{users(:owner).id}:EUR", job.concurrency_key
  end

  test "skips superseded requests and executes the current preference" do
    Rails.cache.clear
    original = ReportingCurrency::Preparation.method(:new)
    calls = []
    fake = Object.new
    fake.define_singleton_method(:call) { calls << :prepared }
    ReportingCurrency::Preparation.define_singleton_method(:new) do |user:, currency:, run_id:|
      calls << [ user.id, currency, run_id ]
      fake
    end
    user = users(:owner)
    job = PrepareReportingCurrencyJob.new
    job.perform(user, currency: "EUR")
    job.perform(user, currency: "EUR", run_id: "missing-run")

    scope = PrepareReportingCurrencyJob.refresh_scope(user:, currency: "EUR")
    RefreshStatus::Tracker.enqueue(scope:, run_id: "current-run")
    job.perform(user, currency: "EUR", run_id: "old-run")
    assert_equal "current-run", RefreshStatus::State.read(scope).run_id
    assert_empty calls

    job.perform(user, currency: "BRL")
    assert_equal user.id, calls.first[0]
    assert_equal "BRL", calls.first[1]
    assert_predicate calls.first[2], :present?
    assert_equal :prepared, calls.last
  ensure
    ReportingCurrency::Preparation.define_singleton_method(:new, original)
  end

  test "completes a queued run when its preference is superseded" do
    user = users(:owner)
    scope = PrepareReportingCurrencyJob.refresh_scope(user:, currency: "EUR")
    RefreshStatus::Tracker.enqueue(scope:, run_id: "superseded-run", supersede: true)

    PrepareReportingCurrencyJob.new.perform(user, currency: "EUR", run_id: "superseded-run")

    assert_equal "succeeded", RefreshStatus::State.read(scope).status
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
