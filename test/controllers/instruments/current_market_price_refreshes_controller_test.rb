require "test_helper"

class Instruments::CurrentMarketPriceRefreshesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @instrument = instruments(:petr4_bvmf)
  end

  test "queues a forced refresh for a supported instrument without requiring a trade" do
    assert_enqueued_with(job: RefreshCurrentMarketPriceJob, args: [ @instrument, { force: true } ]) do
      post instrument_current_market_price_refresh_url(@instrument), as: :turbo_stream
    end

    assert_response :accepted
  end

  test "redirects HTML refreshes to the instrument" do
    post instrument_current_market_price_refresh_url(@instrument)

    assert_redirected_to instrument_url(@instrument)
    assert_equal "Market price refresh started.", flash[:notice]
  end

  test "queues a forced refresh for a supported US instrument" do
    instrument = instruments(:voo_arcx)

    assert_enqueued_with(job: RefreshCurrentMarketPriceJob, args: [ instrument, { force: true } ]) do
      post instrument_current_market_price_refresh_url(instrument), as: :turbo_stream
    end

    assert_response :accepted
  end

  test "rejects an unsupported instrument" do
    instrument = Instrument.create!(
      ticker: "VWRA",
      exchange: "XLON",
      name: "Vanguard FTSE All-World UCITS ETF",
      currency: "USD"
    )

    post instrument_current_market_price_refresh_url(instrument), as: :turbo_stream
    assert_response :not_found
  end
end
