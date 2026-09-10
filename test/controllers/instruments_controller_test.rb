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
    assert_select "#instrument_#{instruments(:petr4_bvmf).id}" do
      assert_select "a", "View details"
      assert_select "a", "Edit instrument"
      assert_select "button:not([disabled])", "Delete"
    end
    assert_select "#instrument_#{instruments(:voo_arcx).id}" do
      assert_select "a", "View details"
      assert_select "a", "Edit instrument"
      assert_select "button[disabled]", "Delete"
    end
  end

  test "shows an instrument without trades as a zero-position state" do
    get instrument_url(@instrument)

    assert_response :success
    assert_select "h1", @instrument.ticker
    assert_select "header [aria-label='Actions for #{@instrument.ticker}']" do
      assert_select "a", "Edit instrument"
      assert_select "button", "Delete"
    end
    assert_select "h2", "Position details"
    assert_select "span", "No trades"
    assert_select "p", "Record a trade to calculate this position."
    assert_select "a", "Add trade"
    assert_select "h2", "Trade history"
    assert_select "p", "No trades for this instrument"
    assert_select "#instrument-performance-heading", "Performance"
    assert_includes response.body, "Record a trade to begin this instrument’s performance history."
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
    assert_select "dt", text: "Gain on cost"
    assert_not_includes response.body, "Realized gains"
    assert_match(/20[,.]00%/, response.body)
    assert_match(/Unrealized return.*\+R\$4,00/m, response.body)
    assert_select "[aria-label='Position currency']", count: 0
  end

  test "shows an interactive chart when historical closing prices are available" do
    2.downto(1) do |days_ago|
      DailyClosingPrice.create!(
        instrument: @instrument,
        trading_date: Date.current - days_ago,
        close_price: 10 + days_ago,
        currency: "BRL",
        provider: "yahoo_finance",
        observed_at: Time.current
      )
    end

    get instrument_url(@instrument, history: "price")

    assert_select "[data-controller='instrument-price-chart'][data-action*='appearance:change']"
    assert_select "canvas[data-instrument-price-chart-target='canvas']"
    assert_select "details summary", "View exact prices"
    assert_select "details tbody tr", count: 2
    assert_includes response.body, "R$12,00"
    assert_includes response.body, "R$11,00"
  end

  test "price history does not prepare unused performance observations" do
    instrument = instruments(:voo_arcx)
    InstrumentPerformanceMaterialization.where(user: users(:owner), instrument:).delete_all

    assert_no_enqueued_jobs only: BuildInstrumentPerformanceObservationsJob do
      get instrument_url(instrument, history: "price")
    end

    assert_response :success
    assert_empty InstrumentPerformanceMaterialization.where(user: users(:owner), instrument:)
  end

  test "renders return-only instrument history in both prepared currency views" do
    instrument = instruments(:voo_arcx)
    selection = Performance::PeriodSelection.for(period: "week", owner: users(:owner), instrument:)
    create_history_observations(instrument:, currency: "USD", range: selection.from..selection.to)
    create_history_observations(instrument:, currency: "BRL", range: selection.from..selection.to)

    get instrument_url(instrument, period: "week")

    assert_response :success
    assert_select "#instrument-performance-heading", "Performance"
    assert_select "[data-controller='performance-chart'][data-performance-chart-default-mode-value='performance'][data-performance-chart-return-only-value='true']", count: 2
    assert_select "[aria-label='Chart view']", count: 0
    assert_select "[aria-label='Position currency']", count: 1
    assert_select "[data-currency-view-name='native']:not([hidden])"
    assert_select "[data-currency-view-name='reporting'][hidden]"
    assert_select "details th", text: "Position value", count: 2
    assert_select "details th", text: "Cost basis", count: 2
    assert_select "details th", text: "Modified Dietz", count: 2
    assert_select "details th", text: "Gain on cost", count: 2
    assert_select "nav[aria-label='Select return methodology']", count: 0
    assert_select "a[href=?]", performance_methodology_path, text: "How returns are calculated", count: 2
    assert_includes response.body, "&quot;portfolio_return_label&quot;:&quot;Modified Dietz&quot;"
    assert_includes response.body, "&quot;gain_on_cost_return_label&quot;:&quot;Gain on cost&quot;"
    assert_not_includes response.body, "Realized gains"
  end

  test "preserves history period and currency state in navigation links" do
    instrument = instruments(:voo_arcx)

    get instrument_url(instrument, history: "price", period: "year", chart: "performance", currency_view: "reporting")
    selected_price_path = instrument_path(
      instrument, history: "price", period: "year", currency_view: "reporting"
    )
    performance_path = instrument_path(
      instrument, history: "performance", period: "year", currency_view: "reporting"
    )
    month_path = instrument_path(
      instrument, history: "price", period: "month", currency_view: "reporting"
    )

    assert_select "nav[aria-label='Select history view']" do
      assert_select "a[aria-current='page'][href=?]", selected_price_path, "Price history"
      assert_select "a[href=?]", performance_path, "Performance"
    end
    assert_select "nav[aria-label='Select reporting period']" do
      assert_select "a[aria-current='page']", "Year"
      assert_select "a[href=?]", month_path, "Month"
    end
    assert_not_includes response.body, "chart=performance"
  end

  test "ignores obsolete methodology query state" do
    instrument = instruments(:voo_arcx)
    selection = Performance::PeriodSelection.for(period: "week", owner: users(:owner), instrument:)
    create_history_observations(instrument:, currency: "USD", range: selection.from..selection.to)
    create_history_observations(instrument:, currency: "BRL", range: selection.from..selection.to)

    get instrument_url(instrument, period: "week", methodology: "gain_on_cost")

    assert_select "nav[aria-label='Select return methodology']", count: 0
    assert_select "details th", text: "Modified Dietz", count: 2
    assert_select "details th", text: "Gain on cost", count: 2
    assert_select "a[href*='methodology=']", count: 0
  end

  test "shows partially available stale missing and failed instrument history states" do
    instrument = instruments(:voo_arcx)
    selection = Performance::PeriodSelection.for(period: "week", owner: users(:owner), instrument:)
    range = selection.from..selection.to
    create_history_observations(instrument:, currency: "USD", range: selection.from..selection.from)

    get instrument_url(instrument, period: "week")
    assert_select "[role='status']", /Instrument history is partially available/

    InstrumentPerformanceObservation.where(user: users(:owner), instrument:, reporting_currency: "USD").delete_all
    create_history_observations(instrument:, currency: "USD", range:, stale_at: Time.current)
    get instrument_url(instrument, period: "week")
    assert_select "[role='status']", /Instrument history may be out of date/

    InstrumentPerformanceObservation.where(user: users(:owner), instrument:, reporting_currency: "USD").delete_all
    create_history_observations(instrument:, currency: "USD", range:, status: :missing)
    get instrument_url(instrument, period: "week")
    assert_select "[role='status']", /Instrument history is incomplete/

    InstrumentPerformanceObservation.where(user: users(:owner), instrument:, reporting_currency: "USD").delete_all
    Rails.cache.clear
    token = Performance::SeriesRefresh.acquire(user: users(:owner), instrument:, reporting_currency: "USD")
    Performance::SeriesRefresh.failed(
      user: users(:owner), instrument:, reporting_currency: "USD", from: range.begin, to: range.end,
      token:, error: RuntimeError.new("calculation failed")
    )
    Performance::SeriesRefresh.release(user: users(:owner), instrument:, reporting_currency: "USD", token:)
    get instrument_url(instrument, period: "week")
    assert_select "[role='alert']", /Instrument history could not be updated/
    assert_select "a", "Try again"
  end

  test "does not replace missing historical values with a current quote" do
    instrument = instruments(:voo_arcx)
    selection = Performance::PeriodSelection.for(period: "week", owner: users(:owner), instrument:)
    create_history_observations(
      instrument:, currency: "USD", range: selection.from..selection.to, status: :missing
    )
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "700", currency: "USD", provider: "yahoo_finance",
        quoted_at: Time.current, fetched_at: Time.current
      )
    )

    get instrument_url(instrument, period: "week")

    assert_select "[role='status']", /Current quotes are never substituted/
    assert_select "[data-controller='performance-chart']", count: 0
  end

  test "renders native and owner-currency gains for a foreign instrument" do
    instrument = Instrument.create!(
      ticker: "PAID", exchange: "XNAS", name: "Paid FX instrument", currency: "USD"
    )
    create_trade(
      instrument:, side: :buy, quantity: 2, unit_price: 200,
      settlement_exchange_rate: "5.25"
    )
    DailyClosingPrice.create!(
      instrument:, trading_date: Date.current, close_price: "220", currency: "USD",
      provider: "yahoo_finance", observed_at: Time.current
    )
    HistoricalExchangeRate.create!(
      base_currency: "USD", quote_currency: "BRL", rate_date: Date.current,
      rate: "5.1", provider: "yahoo_finance_fx", observed_at: Time.current,
      fetched_at: Time.current
    )

    get instrument_url(instrument)

    assert_response :success
    assert_select "[aria-label='Position currency']"
    assert_select "button", text: "USD"
    assert_select "button", text: "BRL"
    assert_select "[data-currency-view-name='native']:not([hidden])", text: /\$440\.00.*\$400\.00/m
    assert_select "[data-currency-view-name='reporting'][hidden]", text: /R\$2.244,00.*R\$2.100,00/m

    get instrument_url(instrument, currency_view: "reporting")

    assert_select "button[data-currency-view-name-param='reporting'][aria-pressed='true']"
    assert_select "[data-currency-view-name='native'][hidden]"
    assert_select "[data-currency-view-name='reporting']:not([hidden])", text: /R\$2.244,00.*R\$2.100,00/m

    get instrument_url(instrument, currency_view: "unsupported")

    assert_select "button[data-currency-view-name-param='native'][aria-pressed='true']"
    assert_select "[data-currency-view-name='native']:not([hidden])"
  end

  test "keeps native performance available when reporting FX is missing" do
    instrument = Instrument.create!(
      ticker: "NOFX", exchange: "XETR", name: "Missing FX instrument", currency: "EUR"
    )
    create_trade(instrument:, side: :buy, quantity: 2, unit_price: 100)
    DailyClosingPrice.create!(
      instrument:, trading_date: Date.current, close_price: "110", currency: "EUR",
      provider: "yahoo_finance", observed_at: Time.current
    )

    get instrument_url(instrument)

    assert_select "[data-currency-view-name='native']", text: /€220,00.*€200,00/m
    assert_select "[data-currency-view-name='reporting']", text: /Performance unavailable/
  end

  test "shows only the configured owner's trades for an instrument" do
    instrument = instruments(:voo_arcx)

    get instrument_url(instrument)

    assert_response :success
    assert_select "h2", "Position details"
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
    assert_select "section[aria-labelledby='position-summary-heading'] dd", text: "R$0,00", minimum: 2
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
    assert_select "[role='status']", /Instrument history is building/
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

  test "renders validation errors when updating an instrument fails" do
    patch instrument_url(@instrument), params: {
      instrument: { ticker: "", exchange: "BAD", name: "", currency: "ZZZ" }
    }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Ticker can't be blank/
    assert_select "[role=alert]", /Exchange is invalid/
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

  def create_history_observations(instrument:, currency:, range:, status: :available, stale_at: nil)
    owner = users(:owner)
    materialization = InstrumentPerformanceMaterialization.for(
      user: owner, instrument:, reporting_currency: currency
    )
    range.each_with_index do |date, index|
      amounts = if status == :missing
        {}
      else
        {
          market_value_amount: 100 + index,
          cost_basis_amount: 90,
          realized_gain_amount: 0,
          unrealized_gain_amount: 10 + index,
          net_cash_flow_amount: -90,
          invested_amount: 90
        }
      end
      InstrumentPerformanceObservation.create!(
        user: owner, instrument:, reporting_currency: currency, observed_on: date,
        status:, source_generation: materialization.source_generation, generated_at: Time.current,
        stale_at:, **amounts
      )
    end
  end

  def create_trade(instrument:, side:, quantity:, traded_on: Date.new(2026, 1, 1),
    unit_price: 10, settlement_exchange_rate: nil)
    User.owner.trades.create!(
      instrument:,
      side:,
      traded_on:,
      quantity:,
      unit_price:,
      fees_cents: 0,
      currency: instrument.currency,
      settlement_exchange_rate:
    )
  end
end
