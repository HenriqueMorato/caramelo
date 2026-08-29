require "test_helper"

class RefreshCurrentMarketPriceJobTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
  end

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

  test "refreshes a foreign exchange rate after refreshing a foreign quote" do
    instrument = instruments(:voo_arcx)
    market_service = Object.new
    market_service.define_singleton_method(:refresh) { |**| }
    exchange_service = Object.new
    calls = []
    exchange_service.define_singleton_method(:refresh) { |**arguments| calls << arguments }

    build_job(service: market_service, exchange_rate_service: exchange_service).perform(instrument)

    assert_equal [ { base_currency: "USD", quote_currency: "BRL" } ], calls
  end

  test "reports an exchange-rate failure without failing the quote refresh" do
    instrument = instruments(:voo_arcx)
    market_service = Object.new
    market_service.define_singleton_method(:refresh) { |**| }
    exchange_service = Object.new
    exchange_service.define_singleton_method(:refresh) { |**| raise ExchangeRate::InvalidValue, "FX unavailable" }
    reports = []

    with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
      build_job(service: market_service, exchange_rate_service: exchange_service).perform(instrument)
    end

    assert_instance_of ExchangeRate::InvalidValue, reports.sole.first
  end

  test "reports known provider failures without failing the job" do
    instrument = instruments(:petr4_bvmf)
    failure = MarketPrice::ProviderFailure.new(provider_identifier: "fake", message: "invalid response")
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

  test "retries rate-limited provider failures using Retry-After" do
    instrument = instruments(:petr4_bvmf)
    failure = MarketPrice::ProviderFailure.new(
      provider_identifier: "yahoo_finance",
      message: "rate limited",
      cause: MarketData::YahooFinance::RateLimited.new(status: 429, headers: { "retry-after" => "60" })
    )
    service = Object.new
    service.define_singleton_method(:refresh) { |**| raise failure }
    retries = []
    job = build_job(service:)
    job.define_singleton_method(:retry_job) { |**options| retries << options }
    job.define_singleton_method(:retry_random) { 0 }
    Rails.cache.write(RefreshCurrentMarketPriceJob.deduplication_key(instrument), true)

    job.perform(instrument)

    assert_equal [ { wait: 60.seconds } ], retries
    assert Rails.cache.exist?(RefreshCurrentMarketPriceJob.deduplication_key(instrument))
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
    assert_equal "RefreshCurrentMarketPriceJob/provider:yahoo_finance",
      RefreshCurrentMarketPriceJob.new(instruments(:petr4_bvmf)).concurrency_key
  end

  test "builds the default broadcaster" do
    assert_instance_of MarketPrice::Broadcaster, RefreshCurrentMarketPriceJob.new.send(:market_price_broadcaster)
  end

  test "builds the default exchange-rate service" do
    assert_instance_of ExchangeRate::Service, RefreshCurrentMarketPriceJob.new.send(:exchange_rate_service)
  end

  test "coalesces duplicate queued refreshes for one instrument" do
    instrument = instruments(:petr4_bvmf)

    first = RefreshCurrentMarketPriceJob.enqueue_for(instrument:)
    second = RefreshCurrentMarketPriceJob.enqueue_for(instrument:)

    assert_instance_of RefreshCurrentMarketPriceJob, first
    assert_equal RefreshCurrentMarketPriceJob::COALESCED, second
    assert_enqueued_jobs 1, only: RefreshCurrentMarketPriceJob
  end

  test "releases the duplicate marker when enqueueing fails" do
    instrument = instruments(:petr4_bvmf)

    with_stubbed_method(RefreshCurrentMarketPriceJob, :perform_later, ->(*) { nil }) do
      assert_nil RefreshCurrentMarketPriceJob.enqueue_for(instrument:)
    end

    assert_not Rails.cache.exist?(RefreshCurrentMarketPriceJob.deduplication_key(instrument))
  end

  test "cleans up the marker when enqueueing raises" do
    instrument = instruments(:petr4_bvmf)
    failure = RuntimeError.new("queue unavailable")

    assert_raises(RuntimeError) do
      with_stubbed_method(RefreshCurrentMarketPriceJob, :perform_later, ->(*) { raise failure }) do
        RefreshCurrentMarketPriceJob.enqueue_for(instrument:)
      end
    end

    assert_not Rails.cache.exist?(RefreshCurrentMarketPriceJob.deduplication_key(instrument))
  end

  test "reports non-retryable market price errors" do
    instrument = instruments(:petr4_bvmf)
    service = Object.new
    service.define_singleton_method(:refresh) { |**| raise MarketPrice::CurrencyMismatch, "wrong currency" }
    reports = []
    job = build_job(service:)

    with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
      job.perform(instrument)
    end

    assert_instance_of MarketPrice::CurrencyMismatch, reports.sole.first
  end

  test "honors an HTTP-date Retry-After value" do
    instrument = instruments(:petr4_bvmf)
    travel_to Time.utc(2026, 8, 28, 15) do
      failure = MarketPrice::ProviderFailure.new(
        provider_identifier: "yahoo_finance",
        message: "rate limited",
        cause: MarketData::YahooFinance::RateLimited.new(
          status: 429, headers: { "retry-after" => (Time.current + 60).httpdate }
        )
      )
      service = Object.new
      service.define_singleton_method(:refresh) { |**| raise failure }
      retries = []
      job = build_job(service:)
      job.define_singleton_method(:retry_job) { |**options| retries << options }
      job.define_singleton_method(:retry_random) { 0 }

      job.perform(instrument)

      assert_equal [ { wait: 60.seconds } ], retries
    end
  end

  test "uses the default retry delay for an invalid Retry-After value" do
    instrument = instruments(:petr4_bvmf)
    failure = MarketPrice::ProviderFailure.new(
      provider_identifier: "yahoo_finance",
      message: "unavailable",
      cause: MarketData::YahooFinance::ProviderUnavailable.new(status: 503, headers: { "retry-after" => "later" })
    )
    service = Object.new
    service.define_singleton_method(:refresh) { |**| raise failure }
    retries = []
    job = build_job(service:)
    job.define_singleton_method(:retry_job) { |**options| retries << options }
    job.define_singleton_method(:retry_random) { 0 }

    job.perform(instrument)

    assert_equal [ { wait: 30.seconds } ], retries
  end

  test "adds bounded jitter to retry delays" do
    error = MarketPrice::ProviderFailure.new(
      provider_identifier: "yahoo_finance",
      message: "rate limited",
      cause: MarketData::YahooFinance::RateLimited.new(status: 429, headers: { "retry-after" => "60" })
    )

    delay = RefreshCurrentMarketPriceJob.new.send(:retry_delay, error)

    assert_operator delay, :>=, 60.seconds
    assert_operator delay, :<=, 66.seconds
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end

  def build_job(service:, broadcaster: null_broadcaster, exchange_rate_service: nil)
    exchange_rate_service ||= Object.new.tap do |exchange_service|
      exchange_service.define_singleton_method(:refresh) { |**| }
    end
    RefreshCurrentMarketPriceJob.new.tap do |job|
      job.define_singleton_method(:market_price_service) { service }
      job.define_singleton_method(:exchange_rate_service) { exchange_rate_service }
      job.define_singleton_method(:market_price_broadcaster) { broadcaster }
      job.define_singleton_method(:market_price_throttle) do
        Object.new.tap { |throttle| throttle.define_singleton_method(:wait!) { |instrument:| } }
      end
    end
  end

  def null_broadcaster
    Object.new.tap do |broadcaster|
      broadcaster.define_singleton_method(:current) { |instrument:| }
    end
  end
end
