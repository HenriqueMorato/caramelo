require "test_helper"

class RefreshTradedMarketPricesJobTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
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

    assert_enqueued_with(job: RefreshCurrentMarketPriceJob, args: [ instrument ]) do
      assert_enqueued_with(job: RefreshCurrentMarketPriceJob, args: [ us_instrument ]) do
        RefreshTradedMarketPricesJob.new.perform
      end
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

    assert_equal (baseline_ids + instruments.map(&:id)).sort,
      enqueued_jobs.map { |job| job[:args].first["_aj_globalid"].split("/").last.to_i }.sort
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
end
