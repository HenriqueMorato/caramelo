require "test_helper"

class BackfillHistoricalMarketDataJobTest < ActiveJob::TestCase
  setup do
    @instrument = instruments(:voo_arcx)
    @backfill = HistoricalDataBackfill.create!(instrument: @instrument, currency: "USD", from_date: Date.new(2026, 1, 1))
    @daily_imports = []
    @exchange_rate_imports = []
    @waits = []
  end

  test "imports price and FX history in bounded batches through the shared throttle" do
    travel_to Date.new(2026, 7, 10) do
      job = build_job

      job.perform(@backfill)
    end

    assert_equal [ [ Date.new(2026, 1, 1), Date.new(2026, 3, 31) ], [ Date.new(2026, 4, 1), Date.new(2026, 6, 29) ], [ Date.new(2026, 6, 30), Date.new(2026, 7, 10) ] ],
      @daily_imports.map { |call| [ call[:from], call[:to] ] }
    assert_equal @daily_imports.map { |call| [ call[:from], call[:to] ] }, @exchange_rate_imports.map { |call| [ call[:from], call[:to] ] }
    assert_equal 6, @waits.length
    assert_equal [ @instrument, nil, @instrument, nil, @instrument, nil ], @waits
    assert_not HistoricalDataBackfill.exists?(@backfill.id)
  end

  test "builds the default importers and shared Yahoo throttle" do
    job = BackfillHistoricalMarketDataJob.new

    assert_instance_of DailyClosingPrice::Importer, job.send(:daily_closing_price_importer)
    assert_instance_of HistoricalExchangeRate::Importer, job.send(:historical_exchange_rate_importer)
    assert_instance_of MarketData::YahooFinance::RequestThrottle, job.send(:request_throttle)
  end

  test "keeps one reporting currency throughout a running backfill" do
    users(:owner).update!(reporting_currency: "EUR")
    job = build_job
    @daily_importer.define_singleton_method(:call) do |**|
      User.owner.update!(reporting_currency: "USD")
    end

    travel_to(Date.new(2026, 7, 10)) { job.perform(@backfill) }

    assert_equal 3, @exchange_rate_imports.size
    assert_equal [ "EUR" ], @exchange_rate_imports.map { |call| call.fetch(:quote_currency) }.uniq
  end

  test "skips FX imports when the trade currency is the reporting currency" do
    @backfill.update!(instrument: instruments(:petr4_bvmf), currency: "BRL")

    travel_to Date.new(2026, 1, 1) do
      assert_equal Date.new(2026, 1, 1), Date.current
      build_job.perform(@backfill)
    end

    assert_equal 1, @daily_imports.size
    assert_empty @exchange_rate_imports
    assert_equal [ instruments(:petr4_bvmf) ], @waits
  end

  test "schedules another run when a request changes while importing" do
    job = build_job
    backfill = @backfill
    daily_imports = @daily_imports
    @daily_importer.define_singleton_method(:call) do |**arguments|
      backfill.update!(from_date: Date.new(2025, 12, 1), generation: backfill.generation + 1)
      daily_imports << arguments
    end

    travel_to Date.new(2026, 1, 1) do
      assert_equal Date.new(2026, 1, 1), Date.current
      job.perform(@backfill)
    end

    assert_enqueued_with(job: BackfillHistoricalMarketDataJob, args: [ @backfill ])
    assert HistoricalDataBackfill.exists?(@backfill.id)
  end

  test "reports terminal provider errors and clears the pending request" do
    job = build_job
    error = MarketData::YahooFinance::InvalidResponse.new("malformed response")
    @daily_importer.define_singleton_method(:call) { |**| raise error }
    reports = []

    with_stubbed_method(Rails.error, :report, ->(reported_error, **context) { reports << [ reported_error, context ] }) do
      job.perform(@backfill)
    end

    assert_equal error, reports.sole.first
    assert_equal @backfill.id, reports.sole.last.fetch(:context).fetch(:historical_data_backfill_id)
    assert_not HistoricalDataBackfill.exists?(@backfill.id)
  end

  test "leaves the request for Active Job to retry a temporary provider error" do
    job = build_job
    error = MarketData::YahooFinance::ProviderUnavailable.new(status: 503)
    @daily_importer.define_singleton_method(:call) { |**| raise error }

    assert_raises(MarketData::YahooFinance::ProviderUnavailable) { job.perform(@backfill) }

    assert HistoricalDataBackfill.exists?(@backfill.id)
  end

  test "reports and clears the request when temporary provider retries are exhausted" do
    job = build_job
    error = MarketData::YahooFinance::ProviderUnavailable.new(status: 503)
    @daily_importer.define_singleton_method(:call) { |**| raise error }
    job.arguments = [ @backfill ]
    job.exception_executions[retry_exceptions.to_s] = BackfillHistoricalMarketDataJob::RETRY_ATTEMPTS - 1
    reports = []

    with_stubbed_method(Rails.error, :report, ->(reported_error, **context) { reports << [ reported_error, context ] }) do
      job.perform_now
    end

    assert_equal error, reports.sole.first
    assert_equal @backfill.id, reports.sole.last.fetch(:context).fetch(:historical_data_backfill_id)
    assert_not HistoricalDataBackfill.exists?(@backfill.id)
  end

  private

  def build_job
    @daily_importer = Object.new
    daily_imports = @daily_imports
    @daily_importer.define_singleton_method(:call) { |**arguments| daily_imports << arguments }
    @exchange_rate_importer = Object.new
    exchange_rate_imports = @exchange_rate_imports
    @exchange_rate_importer.define_singleton_method(:call) { |**arguments| exchange_rate_imports << arguments }
    throttle = Object.new
    waits = @waits
    throttle.define_singleton_method(:wait!) { |instrument: nil| waits << instrument }

    daily_importer = @daily_importer
    historical_exchange_rate_importer = @exchange_rate_importer

    BackfillHistoricalMarketDataJob.new.tap do |job|
      job.define_singleton_method(:daily_closing_price_importer) { daily_importer }
      job.define_singleton_method(:historical_exchange_rate_importer) { historical_exchange_rate_importer }
      job.define_singleton_method(:request_throttle) { throttle }
    end
  end

  def retry_exceptions
    [
      MarketData::YahooFinance::TransportError,
      MarketData::YahooFinance::RateLimited,
      MarketData::YahooFinance::ProviderUnavailable
    ]
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end
end
