require "test_helper"

class CurrentMarketPriceRefreshesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @instrument = instruments(:petr4_bvmf)
    create_trade(@instrument)
  end

  test "queues supported B3 and US owner-traded instruments without authentication" do
    us_instrument = instruments(:voo_arcx)

    assert_enqueued_jobs 2, only: RefreshCurrentMarketPriceJob do
      post current_market_price_refresh_url, as: :turbo_stream
    end

    refresh_jobs = enqueued_jobs.select { |job| job[:job] == RefreshCurrentMarketPriceJob }
    assert refresh_jobs.all? { |job| job[:args].last.stringify_keys["batch_scope"] == RefreshStatus::MARKET_PRICE_SCOPE }
    assert refresh_jobs.all? { |job| job[:args].last.stringify_keys["batch_run_id"].present? }

    assert_response :accepted
    assert_includes response.body, "Market price refresh started."
    assert_includes response.body, "Market data updating"
    assert_includes response.body, "0/2"
  end

  test "redirects HTML refreshes back to positions" do
    post current_market_price_refresh_url

    assert_redirected_to positions_url
    assert_equal "Market price refresh started.", flash[:notice]
  end

  test "rejects a manual refresh during the cooldown window" do
    Rails.cache.write(MarketPrice::ManualRefresh::COOLDOWN_KEY, Time.current)

    post current_market_price_refresh_url, as: :turbo_stream

    assert_response :too_many_requests
    assert_no_enqueued_jobs only: RefreshCurrentMarketPriceJob
  end

  test "completes the manual batch for coalesced instruments" do
    traded_instruments = Instrument.where(id: Trade.where(user: User.owner).select(:instrument_id))
    traded_instruments.each do |instrument|
      Rails.cache.write(RefreshCurrentMarketPriceJob.deduplication_key(instrument), true)
    end

    post current_market_price_refresh_url, as: :turbo_stream

    state = RefreshStatus::State.read(MarketPrice::ManualRefresh::REFRESH_SCOPE)
    assert_equal state.total_count, state.processed_count
    assert_equal "succeeded", state.status
  end

  test "completes immediately when there are no traded instruments" do
    Trade.where(user: User.owner).delete_all

    post current_market_price_refresh_url, as: :turbo_stream

    state = RefreshStatus::State.read(MarketPrice::ManualRefresh::REFRESH_SCOPE)
    assert_equal "succeeded", state.status
    assert_equal "0/0", state.progress_label
  end

  private

  def create_trade(instrument)
    User.owner.trades.create!(
      instrument:,
      side: :buy,
      traded_on: Date.new(2026, 8, 26),
      quantity: 1,
      unit_price: 30,
      fees_cents: 0,
      currency: instrument.currency
    )
  end
end
