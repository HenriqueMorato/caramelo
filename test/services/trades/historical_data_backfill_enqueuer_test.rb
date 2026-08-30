require "test_helper"

class Trades::HistoricalDataBackfillEnqueuerTest < ActiveSupport::TestCase
  test "reports an enqueue failure without raising from the completed trade request" do
    trade = trades(:owner_voo_buy)
    failure = RuntimeError.new("queue unavailable")
    reports = []

    with_stubbed_method(HistoricalDataBackfill, :enqueue_for, ->(**) { raise failure }) do
      with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
        Trades::HistoricalDataBackfillEnqueuer.call(trade:)
      end
    end

    assert_equal failure, reports.sole.first
    assert_equal({ trade_id: trade.id }, reports.sole.last.fetch(:context))
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
