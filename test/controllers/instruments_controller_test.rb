require "test_helper"

class InstrumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @instrument = instruments(:petr4_bvmf)
  end

  test "lists the global instrument catalog" do
    get instruments_url

    assert_response :success
    assert_select "h1", "Instruments"
    assert_select "h2", text: instruments(:petr4_bvmf).ticker
    assert_select "h2", text: instruments(:voo_arcx).ticker
  end

  test "shows an instrument without trades as a zero-position state" do
    get instrument_url(@instrument)

    assert_response :success
    assert_select "h1", @instrument.ticker
    assert_select "h2", "Current position"
    assert_select "span", "No trades"
    assert_select "p", "Record a trade to calculate this position."
    assert_select "a", "Add trade"
    assert_select "h2", "Trade history"
    assert_select "p", "No trades for this instrument"
    assert_includes response.body, "Add a trade and a closing price to see performance here."
    assert_select "#current_market_price_instrument_#{@instrument.id}", text: /Price unavailable/
  end

  test "shows per-instrument performance from the latest closing price" do
    create_trade(instrument: @instrument, side: :buy, quantity: 2)
    DailyClosingPrice.create!(
      instrument: @instrument, trading_date: Date.current - 1, close_price: "12", currency: "BRL",
      provider: "yahoo_finance", observed_at: Time.current
    )

    get instrument_url(@instrument)

    assert_response :success
    assert_select "h2", "Performance"
    assert_select "dd", text: "R$20,00"
    assert_select "dd", text: "R$24,00"
    assert_select "dt", text: "Total return"
    assert_not_includes response.body, "Realized gains"
    assert_includes response.body, "Close as of #{I18n.l(Date.current - 1, format: :long)}"
    assert_match(/20[,.]00%/, response.body)
    assert_match(/Unrealized return.*\+R\$4,00/m, response.body)
  end

  test "shows only the configured owner's trades for an instrument" do
    instrument = instruments(:voo_arcx)

    get instrument_url(instrument)

    assert_response :success
    assert_select "h2", "Current position"
    assert_select "span", "Open"
    assert_select "dd", text: "2.5"
    assert_select "dd", text: "$611.60"
    assert_select "dd", text: "$1,529.00"
    assert_select "article", text: /Long-term allocation/
    assert_select "article", text: /Other owner trade/, count: 0
    assert_select "a", "Add trade"
    assert_select "button[disabled]", "Delete"
    assert_select "[role='tooltip']", "Delete this instrument's trades before deleting the instrument."
    assert_select "[aria-describedby='delete_tooltip_instrument_#{instrument.id}']"
    assert_select "#current_market_price_instrument_#{instrument.id}", text: /Price unavailable/
  end

  test "shows a closed position" do
    create_trade(instrument: @instrument, side: :buy, quantity: 2)
    create_trade(instrument: @instrument, side: :sell, quantity: 2, traded_on: Date.new(2026, 1, 2))

    get instrument_url(@instrument)

    assert_response :success
    assert_select "section[aria-labelledby='position-summary-heading'] span", "Closed"
    assert_select "section[aria-labelledby='position-summary-heading'] dd", text: "0"
    assert_select "section[aria-labelledby='position-summary-heading'] dd", text: "R$0,00", count: 2
  end

  test "identifies an invalid long-only position without hiding trade history" do
    create_trade(instrument: @instrument, side: :sell, quantity: 1)

    get instrument_url(@instrument)

    assert_response :success
    assert_select "span", "Needs attention"
    assert_select "[role='alert']", /Recorded sales exceed purchases on January 01, 2026/
    assert_select "#current_market_price_instrument_#{@instrument.id}", text: /Price unavailable/
    assert_select "h2", "Trade history"
  end

  test "shows a retained B3 price as stale" do
    create_trade(instrument: @instrument, side: :buy, quantity: 1)
    CurrentMarketPriceCache.new.write(
      instrument: @instrument,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "32.45",
        currency: "BRL",
        provider: "yahoo_finance",
        quoted_at: Time.current - 2.hours,
        fetched_at: Time.current - 1.hour
      )
    )

    get instrument_url(@instrument)

    assert_response :success
    assert_select "#current_market_price_instrument_#{@instrument.id}", text: /R\$32,45/
    assert_select "#current_market_price_instrument_#{@instrument.id}", text: /Stale/
  end

  test "shows a loading state while instrument performance is being backfilled" do
    trade = create_trade(instrument: @instrument, side: :buy, quantity: 1)
    HistoricalDataBackfill.create!(instrument: @instrument, currency: trade.currency, from_date: trade.traded_on)

    get instrument_url(@instrument)

    assert_response :success
    assert_select "#instrument-performance-heading", "Performance"
    assert_select "[role='status']", /Performance data is loading/
  end

  test "creates a global instrument" do
    assert_difference("Instrument.count") do
      post instruments_url, params: {
        instrument: {
          ticker: " aapl ",
          exchange: "xnas",
          name: "  Apple   Inc. ",
          currency: "usd",
          user_id: users(:one).id
        }
      }
    end

    instrument = Instrument.order(:id).last
    assert_redirected_to instrument_url(instrument)
    assert_equal "AAPL", instrument.ticker
    assert_equal "XNAS", instrument.exchange
    assert_equal "Apple Inc.", instrument.name
    assert_equal "USD", instrument.currency
    assert_equal "other", instrument.asset_type
  end

  test "creates an instrument with a selected category" do
    post instruments_url, params: {
      instrument: {
        ticker: "BTC", exchange: "XNAS", name: "Bitcoin", currency: "USD", asset_type: "crypto"
      }
    }

    assert_redirected_to instrument_url(Instrument.order(:id).last)
    assert_predicate Instrument.order(:id).last, :crypto?
  end

  test "defaults a new instrument to BVMF and BRL" do
    get new_instrument_url

    assert_response :success
    assert_select "input[name='instrument[exchange]'][value='BVMF']"
    assert_select "input[name='instrument[currency]'][value='BRL']"
  end

  test "renders validation errors when creation fails" do
    assert_no_difference("Instrument.count") do
      post instruments_url, params: { instrument: { ticker: "", exchange: "BAD", name: "", currency: "ZZZ" } }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Ticker can't be blank/
    assert_select "[role=alert]", /Exchange is invalid/
    assert_select "[role=alert]", /Name can't be blank/
    assert_select "[role=alert]", /Currency is invalid/
  end

  test "updates an instrument" do
    patch instrument_url(@instrument), params: {
      instrument: { ticker: "petr3", exchange: "bvmf", name: "Petrobras ON", currency: "usd" }
    }

    assert_redirected_to instrument_url(@instrument)
    assert_equal "PETR3", @instrument.reload.ticker
    assert_equal "BVMF", @instrument.exchange
    assert_equal "Petrobras ON", @instrument.name
    assert_equal "USD", @instrument.currency
  end

  test "deletes an unused instrument" do
    assert_difference("Instrument.count", -1) do
      delete instrument_url(@instrument)
    end

    assert_redirected_to instruments_url
  end

  test "does not delete an instrument with trades" do
    instrument = instruments(:voo_arcx)

    assert_no_difference("Instrument.count") do
      delete instrument_url(instrument)
    end

    assert_redirected_to instrument_url(instrument)
    assert_match(/dependent trades exist/, flash[:alert])
  end

  private

  def create_trade(instrument:, side:, quantity:, traded_on: Date.new(2026, 1, 1))
    User.owner.trades.create!(
      instrument:,
      side:,
      traded_on:,
      quantity:,
      unit_price: 10,
      fees_cents: 0,
      currency: instrument.currency
    )
  end
end
