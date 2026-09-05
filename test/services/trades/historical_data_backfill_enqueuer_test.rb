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

  test "prepares FX when an edit introduces a settlement currency different from reporting" do
    trade = trades(:owner_voo_buy)
    trade.update!(settlement_exchange_rate: "5.25")
    trade.user.update!(reporting_currency: "EUR")
    preparations = []

    trade.update!(settlement_exchange_rate: "5.3")

    with_stubbed_method(PrepareReportingCurrencyJob, :enqueue_for, ->(**args) { preparations << args }) do
      Trades::HistoricalDataBackfillEnqueuer.call(trade:)
    end

    assert_equal [ { user: trade.user } ], preparations
  end

  test "does not prepare reporting currency when settlement already matches it" do
    trade = trades(:owner_voo_buy)
    trade.update!(settlement_exchange_rate: "5.25")
    preparations = []

    with_stubbed_method(PrepareReportingCurrencyJob, :enqueue_for, ->(**args) { preparations << args }) do
      Trades::HistoricalDataBackfillEnqueuer.call(trade:)
    end

    assert_empty preparations
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
