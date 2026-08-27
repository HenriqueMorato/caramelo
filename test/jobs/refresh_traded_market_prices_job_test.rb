require "test_helper"

class RefreshTradedMarketPricesJobTest < ActiveJob::TestCase
  test "enqueues each supported instrument traded by the owner including a closed holding" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    create_trade(instrument:, side: :sell, quantity: 1)
    untraded_instrument = Instrument.create!(
      ticker: "VALE3",
      exchange: "BVMF",
      name: "Vale ON",
      currency: "BRL"
    )

    assert_enqueued_with(job: RefreshCurrentMarketPriceJob, args: [ instrument ]) do
      RefreshTradedMarketPricesJob.new.perform
    end
    assert_no_enqueued_jobs only: RefreshCurrentMarketPriceJob do
      build_job(service: unsupported_service).perform
    end
    assert_not User.owner.trades.exists?(instrument: untraded_instrument)
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
