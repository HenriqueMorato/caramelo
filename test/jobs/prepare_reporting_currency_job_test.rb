require "test_helper"

class PrepareReportingCurrencyJobTest < ActiveJob::TestCase
  test "enqueues the saved currency" do
    assert PrepareReportingCurrencyJob.enqueue_for(user: users(:owner))
    assert_enqueued_with(job: PrepareReportingCurrencyJob, args: [ users(:owner), { currency: "BRL" } ])
  end

  test "reports queue failure without discarding the preference" do
    original = PrepareReportingCurrencyJob.method(:perform_later)
    PrepareReportingCurrencyJob.define_singleton_method(:perform_later) { |*| raise ActiveJob::EnqueueError }

    assert_not PrepareReportingCurrencyJob.enqueue_for(user: users(:owner))
  ensure
    PrepareReportingCurrencyJob.define_singleton_method(:perform_later, original)
  end

  test "skips superseded requests and executes the current preference" do
    original = ReportingCurrency::Preparation.method(:new)
    calls = []
    fake = Object.new
    fake.define_singleton_method(:call) { calls << :prepared }
    ReportingCurrency::Preparation.define_singleton_method(:new) do |user:, currency:|
      calls << [ user.id, currency ]
      fake
    end
    user = users(:owner)
    job = PrepareReportingCurrencyJob.new
    job.perform(user, currency: "EUR")
    assert_empty calls

    job.perform(user, currency: "BRL")
    assert_equal [ [ user.id, "BRL" ], :prepared ], calls
  ensure
    ReportingCurrency::Preparation.define_singleton_method(:new, original)
  end
end
