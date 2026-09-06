require "test_helper"

class RefreshTradedMarketPricesJobTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
  end

  test "coalesces coordinator enqueues while one is pending" do
    clear_enqueued_jobs

    first = RefreshTradedMarketPricesJob.enqueue_for
    second = RefreshTradedMarketPricesJob.enqueue_for

    assert_instance_of RefreshTradedMarketPricesJob, first
    assert_equal :coalesced, second
    assert_equal 1, enqueued_jobs.size
  end

  test "clears the coordinator marker when enqueueing fails" do
    failure = RuntimeError.new("queue unavailable")
    with_stubbed_method(RefreshTradedMarketPricesJob, :perform_later, -> { raise failure }) do
      assert_raises(RuntimeError) { RefreshTradedMarketPricesJob.enqueue_for }
    end

    assert_not Rails.cache.exist?(RefreshTradedMarketPricesJob.send(:deduplication_key))
  end

  test "clears the coordinator marker when the adapter declines the enqueue" do
    with_stubbed_method(RefreshTradedMarketPricesJob, :perform_later, -> { nil }) do
      assert_nil RefreshTradedMarketPricesJob.enqueue_for
    end

    assert_not Rails.cache.exist?(RefreshTradedMarketPricesJob.send(:deduplication_key))
  end

  test "enqueues each supported instrument traded by the owner including a closed holding" do
    instrument = instruments(:petr4_bvmf)
    us_instrument = instruments(:voo_arcx)
    create_trade(instrument:, side: :buy, quantity: 1)
    create_trade(instrument:, side: :sell, quantity: 1)
    untraded_instrument = Instrument.create!(
      ticker: "VALE3",
      exchange: "BVMF",
      name: "Vale ON",
      currency: "BRL"
    )

    assert_enqueued_jobs 2, only: RefreshCurrentMarketPriceJob do
      RefreshTradedMarketPricesJob.new.perform
    end

    refresh_jobs = enqueued_jobs.select { |job| job[:job] == RefreshCurrentMarketPriceJob }
    assert refresh_jobs.all? { |job| job[:args].last.stringify_keys["batch_scope"] == RefreshStatus::MARKET_PRICE_SCOPE }
    assert refresh_jobs.all? { |job| job[:args].last.stringify_keys["batch_run_id"].present? }
    refresh_jobs.each do |job|
      instrument_id = job[:args].first["_aj_globalid"].split("/").last.to_i
      state = RefreshStatus::State.read("current_market_price:#{instrument_id}")
      assert_equal job[:args].last.stringify_keys["batch_run_id"], state.run_id
    end
    assert_no_enqueued_jobs only: RefreshCurrentMarketPriceJob do
      build_job(service: unsupported_service).perform
    end
    assert_not User.owner.trades.exists?(instrument: untraded_instrument)
  end

  test "handles a representative 45-instrument refresh without duplicate jobs" do
    baseline_ids = User.owner.trades.distinct.pluck(:instrument_id)
    instruments = 45.times.map do |index|
      instrument = Instrument.create!(
        ticker: "BULK#{index}", exchange: "XNAS", name: "Bulk ETF #{index}", currency: "USD"
      )
      create_trade(instrument:, side: :buy, quantity: 1)
      instrument
    end

    assert_enqueued_jobs baseline_ids.length + 45, only: RefreshCurrentMarketPriceJob do
      RefreshTradedMarketPricesJob.new.perform
      RefreshTradedMarketPricesJob.new.perform
    end

    refresh_jobs = enqueued_jobs.select { |job| job[:job] == RefreshCurrentMarketPriceJob }
    assert_equal (baseline_ids + instruments.map(&:id)).sort,
      refresh_jobs.map { |job| job[:args].first["_aj_globalid"].split("/").last.to_i }.sort
  end

  test "skips an instrument whose cached quote is still fresh" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "30", currency: instrument.currency, provider: "yahoo_finance",
        quoted_at: Time.current, fetched_at: Time.current
      )
    )

    clear_enqueued_jobs
    RefreshTradedMarketPricesJob.new.perform

    refute enqueued_jobs.any? { |job| job[:args].first["_aj_globalid"].end_with?("Instrument/#{instrument.id}") }
  end

  test "skips a supported instrument when its lookup is not refreshable" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| true }
    service.define_singleton_method(:read) { |instrument:| Struct.new(:refresh_needed?).new(false) }

    clear_enqueued_jobs
    build_job(service:).perform

    assert_no_enqueued_jobs only: RefreshCurrentMarketPriceJob
  end

  test "skips a supported instrument when its quote lookup is missing" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| true }
    service.define_singleton_method(:read) { |instrument:| nil }

    clear_enqueued_jobs
    build_job(service:).perform

    assert_no_enqueued_jobs only: RefreshCurrentMarketPriceJob
  end

  private

  def create_trade(instrument:, side:, quantity:)
    User.owner.trades.create!(
      instrument:,
      side:,
      traded_on: Date.new(2026, 8, 26),
      quantity:,
      unit_price: 30,
      fees_cents: 0,
      currency: instrument.currency
    )
  end

  def unsupported_service
    Object.new.tap do |service|
      service.define_singleton_method(:supports?) { |instrument:| false }
    end
  end

  def build_job(service:)
    RefreshTradedMarketPricesJob.new.tap do |job|
      job.define_singleton_method(:market_price_service) { service }
    end
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end
end
