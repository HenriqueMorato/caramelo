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

  test "resumes an active coordinator without creating a new run or completing coalesced children" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    clear_enqueued_jobs

    RefreshTradedMarketPricesJob.new.perform
    first = RefreshStatus::State.read(RefreshStatus::MARKET_PRICE_SCOPE)

    RefreshTradedMarketPricesJob.new.perform
    second = RefreshStatus::State.read(RefreshStatus::MARKET_PRICE_SCOPE)

    assert_equal first.run_id, second.run_id
    assert_equal "running", second.status
    assert_equal 0, second.processed_count
    instrument_jobs = enqueued_jobs.select do |job|
      job[:job] == RefreshCurrentMarketPriceJob &&
        job[:args].first["_aj_globalid"].end_with?("Instrument/#{instrument.id}")
    end
    assert_equal 1, instrument_jobs.size
  end

  test "does not count a fresh instrument twice while another child is pending" do
    fresh = instruments(:petr4_bvmf)
    stale = instruments(:voo_arcx)
    create_trade(instrument: fresh, side: :buy, quantity: 1)
    create_trade(instrument: stale, side: :buy, quantity: 1)
    instrument_ids = [ fresh.id, stale.id ]
    lookup = Struct.new(:refresh_needed?)
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| true }
    service.define_singleton_method(:read) { |instrument:| lookup.new(instrument.id == stale.id) }
    job = build_job(service:, instruments: instrument_ids) do
      instrument_ids
    end

    job.perform
    first = RefreshStatus::State.read(RefreshStatus::MARKET_PRICE_SCOPE)
    job.perform
    second = RefreshStatus::State.read(RefreshStatus::MARKET_PRICE_SCOPE)

    assert_equal first.run_id, second.run_id
    assert_equal 1, second.processed_count
    assert_equal 2, second.total_count
    assert_equal "running", second.status
  end

  test "starts a new run when an active state predates keyed progress" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    old_run = "legacy-run"
    Rails.cache.write(
      RefreshStatus::State.send(:key, RefreshStatus::MARKET_PRICE_SCOPE),
      {
        scope: RefreshStatus::MARKET_PRICE_SCOPE, run_id: old_run, status: "running",
        started_at: Time.current.iso8601, finished_at: nil, updated_at: Time.current.iso8601,
        error_class: nil, error_message: nil, processed_count: 0, total_count: 1
      }
    )

    RefreshTradedMarketPricesJob.new.perform

    state = RefreshStatus::State.read(RefreshStatus::MARKET_PRICE_SCOPE)
    assert_not_equal old_run, state.run_id
  end

  test "reconciles keyed progress when the traded instrument set changes" do
    retained = instruments(:petr4_bvmf)
    removed = instruments(:voo_arcx)
    create_trade(instrument: retained, side: :buy, quantity: 1)
    create_trade(instrument: removed, side: :buy, quantity: 1)
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| true }
    service.define_singleton_method(:read) { |instrument:| Struct.new(:refresh_needed?).new(false) }
    previous = RefreshStatus::Tracker.enqueue(
      scope: RefreshStatus::MARKET_PRICE_SCOPE,
      total_count: 2,
      tracked_items: [ retained.id, removed.id ]
    )
    RefreshStatus::Tracker.advance(previous, key: retained.id)

    job = build_job(service:, instruments: [ retained ])
    job.perform

    state = RefreshStatus::State.read(RefreshStatus::MARKET_PRICE_SCOPE)
    assert_equal [ retained.id.to_s ], state.tracked_items
    assert_equal [ retained.id.to_s ], state.completed_items
    assert_equal 1, state.processed_count
    assert_equal "succeeded", state.status
  end

  test "reconciles the parent when a child succeeded before parent bookkeeping" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| true }
    service.define_singleton_method(:read) { |instrument:| Struct.new(:refresh_needed?).new(true) }
    parent = RefreshStatus::Tracker.enqueue(
      scope: RefreshStatus::MARKET_PRICE_SCOPE, total_count: 1, tracked_items: [ instrument.id ]
    )
    child_scope = RefreshCurrentMarketPriceJob.refresh_scope(instrument)
    child = RefreshStatus::Tracker.enqueue(scope: child_scope, run_id: parent.run_id, total_count: 1)
    RefreshStatus::Tracker.advance(child)

    build_job(service:, instruments: [ instrument ]).perform

    state = RefreshStatus::State.read(parent.scope)
    assert_equal "succeeded", state.status
    assert_equal 1, state.processed_count
    assert_equal [ instrument.id.to_s ], state.completed_items
  end

  test "fails the parent when a child had already failed" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| true }
    service.define_singleton_method(:read) { |instrument:| Struct.new(:refresh_needed?).new(true) }
    parent = RefreshStatus::Tracker.enqueue(
      scope: RefreshStatus::MARKET_PRICE_SCOPE, total_count: 1, tracked_items: [ instrument.id ]
    )
    child_scope = RefreshCurrentMarketPriceJob.refresh_scope(instrument)
    child = RefreshStatus::Tracker.enqueue(scope: child_scope, run_id: parent.run_id, total_count: 1)
    RefreshStatus::Tracker.record_failure(child, RuntimeError.new("quote unavailable"))

    build_job(service:, instruments: [ instrument ]).perform

    assert_equal "failed", RefreshStatus::State.read(parent.scope).status
    assert_equal "quote unavailable", RefreshStatus::State.read(parent.scope).error_message
  end

  test "fails the coordinator when a child cannot be enqueued" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)

    with_stubbed_method(RefreshCurrentMarketPriceJob, :enqueue_for, ->(**) { nil }) do
      assert_raises RefreshTradedMarketPricesJob::EnqueueFailure do
        RefreshTradedMarketPricesJob.new.perform
      end
    end

    state = RefreshStatus::State.read(RefreshStatus::MARKET_PRICE_SCOPE)
    assert_equal "failed", state.status
    assert_includes state.error_message, "could not enqueue"
  end

  test "coalesces coordinator executions" do
    job = RefreshTradedMarketPricesJob.new

    assert_equal :discard, RefreshTradedMarketPricesJob.concurrency_on_conflict
    assert_equal 1, RefreshTradedMarketPricesJob.concurrency_limit
    assert_equal RefreshTradedMarketPricesJob::DEDUPLICATION_WINDOW,
      RefreshTradedMarketPricesJob.concurrency_duration
    assert_equal "#{RefreshTradedMarketPricesJob.name}/#{RefreshTradedMarketPricesJob::COORDINATOR_CONCURRENCY_KEY}",
      job.concurrency_key
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

  test "supersedes an older per-instrument refresh run" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    old_state = RefreshStatus::Tracker.enqueue(
      scope: RefreshCurrentMarketPriceJob.refresh_scope(instrument), run_id: "old-run"
    )

    RefreshTradedMarketPricesJob.new.perform

    job = enqueued_jobs.find { |entry| entry[:job] == RefreshCurrentMarketPriceJob }
    state = RefreshStatus::State.read(old_state.scope)

    assert_not_nil job
    assert_not_equal "old-run", state.run_id
    assert_equal job[:args].last.stringify_keys["batch_run_id"], state.run_id
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

  test "includes every account's instruments in multi mode" do
    job = RefreshTradedMarketPricesJob.new

    with_stubbed_method(Caramelo::AccountMode, :multi?, -> { true }) do
      assert_equal Trade.distinct.pluck(:instrument_id).sort, job.send(:traded_instruments).pluck(:id).sort
    end
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

  def build_job(service:, instruments: nil, &instrument_ids)
    RefreshTradedMarketPricesJob.new.tap do |job|
      job.define_singleton_method(:market_price_service) { service }
      next unless instruments

      job.define_singleton_method(:traded_instruments) do
        Instrument.where(id: (instrument_ids ? instrument_ids.call : instruments.map(&:id)))
      end
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
