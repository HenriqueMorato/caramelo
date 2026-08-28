require "test_helper"

class RefreshCurrentMarketPriceJobTest < ActiveJob::TestCase
  test "refreshes through the default service" do
    instrument = instruments(:petr4_bvmf)
    calls = []
    service = Object.new
    service.define_singleton_method(:refresh) { |**arguments| calls << arguments }
    broadcaster = null_broadcaster

    with_stubbed_method(MarketPrice::Service, :default, -> { service }) do
      with_stubbed_method(MarketPrice::Broadcaster, :new, -> { broadcaster }) do
        RefreshCurrentMarketPriceJob.perform_now(instrument, force: true)
      end
    end

    assert_equal [ { instrument:, force: true } ], calls
  end

  test "broadcasts the final cache state after refreshing" do
    instrument = instruments(:petr4_bvmf)
    service = Object.new
    service.define_singleton_method(:refresh) { |**| }
    broadcasts = []
    broadcaster = Object.new
    broadcaster.define_singleton_method(:current) { |instrument:| broadcasts << instrument }
    job = build_job(service:, broadcaster:)

    job.perform(instrument)

    assert_equal [ instrument ], broadcasts
  end

  test "reports known provider failures without failing the job" do
    instrument = instruments(:petr4_bvmf)
    failure = MarketPrice::ProviderFailure.new(provider_identifier: "fake", message: "unavailable")
    service = Object.new
    service.define_singleton_method(:refresh) { |**| raise failure }
    reports = []
    job = build_job(service:)

    with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
      job.perform(instrument)
    end

    report = reports.sole
    assert_equal failure, report.first
    assert_equal true, report.second.fetch(:handled)
    assert_equal({ instrument_id: instrument.id }, report.second.fetch(:context))
  end

  test "reports broadcast failures without failing the job" do
    instrument = instruments(:petr4_bvmf)
    failure = RuntimeError.new("broadcast unavailable")
    service = Object.new
    service.define_singleton_method(:refresh) { |**| }
    broadcaster = Object.new
    broadcaster.define_singleton_method(:current) { |**| raise failure }
    reports = []

    with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
      build_job(service:, broadcaster:).perform(instrument)
    end

    assert_equal failure, reports.sole.first
    assert_equal({ instrument_id: instrument.id }, reports.sole.second.fetch(:context))
  end

  test "blocks rather than discarding a concurrent manual refresh" do
    assert_equal :block, RefreshCurrentMarketPriceJob.concurrency_on_conflict
    assert_equal 1, RefreshCurrentMarketPriceJob.concurrency_limit
    assert_equal 2.minutes, RefreshCurrentMarketPriceJob.concurrency_duration
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end

  def build_job(service:, broadcaster: null_broadcaster)
    RefreshCurrentMarketPriceJob.new.tap do |job|
      job.define_singleton_method(:market_price_service) { service }
      job.define_singleton_method(:market_price_broadcaster) { broadcaster }
    end
  end

  def null_broadcaster
    Object.new.tap do |broadcaster|
      broadcaster.define_singleton_method(:current) { |instrument:| }
    end
  end
end
