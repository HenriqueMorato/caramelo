require "test_helper"

class CorporateActions::HistoricalDataBackfillEnqueuerTest < ActiveSupport::TestCase
  setup do
    @action = CorporateAction.new(
      user: users(:owner), instrument: instruments(:voo_arcx), kind: :dividend,
      status: :confirmed, paid_on: Date.new(2026, 8, 25), gross_amount_cents: 100,
      withholding_tax_cents: 0, net_amount_cents: 100, currency: "USD", source: "manual"
    )
  end

  test "requests history from the performance date for confirmed income" do
    @action.ex_date = @action.paid_on - 5.days
    requests = []

    with_stubbed_method(HistoricalDataBackfill, :enqueue_for, ->(**attributes) { requests << attributes }) do
      CorporateActions::HistoricalDataBackfillEnqueuer.call(corporate_action: @action)
    end

    assert_equal [ {
      instrument: @action.instrument,
      currency: "USD",
      from_date: @action.ex_date
    } ], requests
  end

  test "does not request history for an ineffective action" do
    @action.status = :pending
    requests = []

    with_stubbed_method(HistoricalDataBackfill, :enqueue_for, ->(**attributes) { requests << attributes }) do
      CorporateActions::HistoricalDataBackfillEnqueuer.call(corporate_action: @action)
    end

    assert_empty requests
  end

  test "reports an enqueue failure without failing the completed write" do
    failure = RuntimeError.new("queue unavailable")
    reports = []

    with_stubbed_method(HistoricalDataBackfill, :enqueue_for, ->(**) { raise failure }) do
      with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
        CorporateActions::HistoricalDataBackfillEnqueuer.call(corporate_action: @action)
      end
    end

    assert_equal failure, reports.sole.first
    assert_equal({ corporate_action_id: nil }, reports.sole.last.fetch(:context))
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end
end
