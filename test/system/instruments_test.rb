require "application_system_test_case"

class InstrumentsTest < ApplicationSystemTestCase
  setup do
    page.current_window.resize_to(390, 844)
  end

  test "lists the instrument catalog" do
    visit instruments_path

    assert_text "PETR4", count: 1
    assert_text "Petrobras PN", count: 1
    assert_text "VOO"
    assert_text "Vanguard S&P 500 ETF"
  end

  test "shows an empty state without instruments" do
    # Clear every instrument foreign key before exercising the empty catalog.
    CorporateActionImport.delete_all
    CorporateActionImportScan.delete_all
    CorporateAction.delete_all
    DailyClosingPrice.delete_all
    HistoricalDataBackfill.delete_all
    InstrumentPerformanceObservation.delete_all
    InstrumentPerformanceMaterialization.delete_all
    PositionMaterialization.delete_all
    Trade.delete_all
    Instrument.delete_all

    visit instruments_path

    assert_text "No instruments yet"
    assert_link "Add instrument"
  end

  test "creates a multi-currency instrument" do
    visit new_instrument_path

    assert_field "Exchange", with: "BVMF"
    assert_field "Currency", with: "BRL"

    fill_in "Ticker", with: "aapl"
    fill_in "Exchange", with: "xnas"
    fill_in "Name", with: "Apple Inc."
    fill_in "Currency", with: "usd"
    click_on "Create Instrument"

    assert_text "Instrument was created."
    assert_text "AAPL"
    assert_text "Apple Inc."
    assert_text "Other"
    assert_text "USD"
    assert_text "Activity history"
  end

  test "edits an instrument" do
    instrument = instruments(:petr4_bvmf)

    visit edit_instrument_path(instrument)
    fill_in "Ticker", with: "petr3"
    fill_in "Name", with: "Petrobras ON"
    click_on "Update Instrument"

    assert_current_path instrument_path(instrument)
    assert_text "Instrument was updated."
    assert_text "PETR3"
    assert_text "Petrobras ON"
  end

  test "shows validation errors while editing" do
    instrument = instruments(:petr4_bvmf)

    visit edit_instrument_path(instrument)
    fill_in "Ticker", with: "voo"
    fill_in "Exchange", with: "arcx"
    fill_in "Currency", with: "ZZZ"
    click_on "Update Instrument"

    assert_text "2 errors prevented this instrument from being saved:"
    assert_text "Ticker has already been taken"
    assert_text "Currency is invalid"
    assert_field "Ticker", with: "voo"
    assert_field "Currency", with: "ZZZ"
  end

  test "deletes an instrument with confirmation" do
    instrument = instruments(:petr4_bvmf)

    visit instrument_path(instrument)

    accept_confirm "Delete PETR4?" do
      click_on "Delete"
    end

    assert_current_path instruments_path
    assert_text "Instrument was deleted."
    assert_no_text "PETR4"
  end

  test "explains why an instrument with trades cannot be deleted" do
    instrument = instruments(:voo_arcx)
    tooltip_id = "delete_tooltip_instrument_#{instrument.id}"

    visit instrument_path(instrument)

    assert_button "Delete", disabled: true
    tooltip_trigger = find("[aria-describedby='#{tooltip_id}']")
    page.execute_script("arguments[0].focus()", tooltip_trigger)

    assert_selector "[aria-describedby='#{tooltip_id}']:focus"
    assert_selector "##{tooltip_id}", text: "Delete this instrument's trades and income before deleting the instrument.",
      visible: true
  end

  test "updates an instrument position after contextual trade changes" do
    instrument = instruments(:petr4_bvmf)

    visit instrument_path(instrument)

    assert_text "No trades"
    within "[aria-labelledby='activity-history-heading']" do
      find("summary", text: "Add").click
      assert_link "Trade"
      assert_link "Income"
    end
    within "[aria-labelledby='position-summary-heading']" do
      click_on "Add trade"
    end

    find("input[name='trade[traded_on]']:not([disabled])").set("2026-08-24")
    fill_in "Quantity", with: "3"
    fill_in "Unit price", with: "20"
    fill_in "Fees", with: "0"
    click_on "Create Trade"
    assert_current_path transactions_path

    visit instrument_path(instrument)
    within "[aria-labelledby='position-summary-heading']" do
      assert_text "Open"
      assert_text "3"
      assert_text "R$20,00"
      assert_text "R$60,00"
    end

    within "#trade_#{Trade.where(user: User.owner, instrument:).sole.id}" do
      click_on "Edit"
    end
    fill_in "Quantity", with: "4"
    click_on "Update Trade"
    assert_current_path instrument_path(instrument)
    within "[aria-labelledby='position-summary-heading']" do
      assert_text "4"
      assert_text "R$80,00"
    end

    trade = Trade.where(user: User.owner, instrument:).sole
    within "#trade_#{trade.id}" do
      accept_confirm "Delete this trade?" do
        click_on "Delete"
      end
    end
    assert_current_path instrument_path(instrument)
    within "[aria-labelledby='position-summary-heading']" do
      assert_text "No trades"
      assert_link "Add trade"
    end
  end

  test "switches foreign performance between instrument and owner currencies" do
    instrument = Instrument.create!(
      ticker: "PAID", exchange: "XNAS", name: "Paid FX instrument", currency: "USD"
    )
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on: Date.current, quantity: 2,
      unit_price: 200, fees_cents: 0, currency: "USD", settlement_exchange_rate: "5.25"
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

    visit instrument_path(instrument)

    within "[aria-labelledby='position-summary-heading']" do
      assert_text "$400.00"
      click_on "BRL"
      assert_text "R$2.100,00"
    end
    assert_current_path instrument_path(instrument, currency_view: "reporting")

    refresh

    within "[aria-labelledby='position-summary-heading']" do
      assert_text "R$2.100,00"
      assert_no_text "$400.00"
    end

    page.go_back

    within "[aria-labelledby='position-summary-heading']" do
      assert_text "$400.00"
      assert_no_text "R$2.100,00"
    end
  end

  test "navigates return-only performance and price history with restorable URL state" do
    instrument = instruments(:voo_arcx)
    selection = Performance::PeriodSelection.for(period: "week", owner: User.owner, instrument:)
    create_performance_history(instrument:, currency: "USD", range: selection.from..selection.to)
    create_performance_history(instrument:, currency: "BRL", range: selection.from..selection.to)
    [ selection.from, selection.to ].each_with_index do |date, index|
      DailyClosingPrice.create!(
        instrument:, trading_date: date, close_price: 620 + index,
        currency: "USD", provider: "yahoo_finance", observed_at: Time.current
      )
    end

    visit instrument_path(instrument, period: "week")

    within "[aria-labelledby='instrument-performance-heading']" do
      assert_text "Performance"
      assert_no_selector "[aria-label='Chart view']"
      assert_selector "canvas[data-performance-chart-target='canvas']"
    end
    assert_equal [ "portfolio-return" ], visible_chart_dataset_roles

    within "[aria-labelledby='instrument-performance-heading']" do
      click_on "Price history"
      assert_selector "canvas[data-instrument-price-chart-target='canvas']"
      click_on "Month"
    end
    assert_current_path instrument_path(
      instrument, history: "price", period: "month", currency_view: "native"
    ), ignore_query: false

    page.go_back
    assert_current_path instrument_path(
      instrument, history: "price", period: "week", currency_view: "native"
    ), ignore_query: false
    page.go_back
    assert_current_path instrument_path(instrument, period: "week"), ignore_query: false
    assert_selector "canvas[data-performance-chart-target='canvas']"

    within "[aria-labelledby='position-summary-heading']" do
      click_on "BRL"
    end
    assert_current_path instrument_path(instrument), ignore_query: true
    assert_equal({ "period" => "week", "currency_view" => "reporting" }, current_query_parameters)
    assert_selector "[data-currency-view-name='reporting']:not([hidden]) canvas[data-performance-chart-target='canvas']"
    assert_equal [ "portfolio-return" ], visible_chart_dataset_roles
  end

  test "reveals gain on cost from the chart legend and explains the calculations" do
    instrument = instruments(:voo_arcx)
    selection = Performance::PeriodSelection.for(period: "week", owner: User.owner, instrument:)
    create_performance_history(instrument:, currency: "USD", range: selection.from..selection.to)
    create_performance_history(instrument:, currency: "BRL", range: selection.from..selection.to)

    visit instrument_path(instrument, period: "week")

    assert_equal [ "portfolio-return", "gain-on-cost-return" ], chart_dataset_roles
    assert_equal [ "portfolio-return" ], visible_chart_dataset_roles

    select_chart_legend_item("Gain on cost")

    assert_equal [ "portfolio-return", "gain-on-cost-return" ], visible_chart_dataset_roles
    assert_current_path instrument_path(instrument, period: "week"), ignore_query: false
    within "[aria-labelledby='instrument-performance-heading']" do
      within "[data-currency-view-name='native']" do
        click_on "How returns are calculated"
      end
    end

    assert_current_path performance_methodology_path
    assert_text "Same position, different answers"
    page.go_back
    assert_current_path instrument_path(instrument, period: "week"), ignore_query: false
    assert_selector "canvas[data-performance-chart-target='canvas']"
    assert_equal [ "portfolio-return" ], visible_chart_dataset_roles
  end

  private

  def create_performance_history(instrument:, currency:, range:)
    materialization = InstrumentPerformanceMaterialization.for(
      user: User.owner, instrument:, reporting_currency: currency
    )
    range.each_with_index do |date, index|
      InstrumentPerformanceObservation.create!(
        user: User.owner, instrument:, reporting_currency: currency, observed_on: date,
        status: :available, source_generation: materialization.source_generation,
        generated_at: Time.current, market_value_amount: 1_500 + index,
        cost_basis_amount: 1_400, realized_gain_amount: 0,
        unrealized_gain_amount: 100 + index, net_cash_flow_amount: -1_400,
        investment_income_amount: 0, invested_amount: 1_400
      )
    end
  end

  def visible_chart_dataset_roles
    page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const element = document.querySelector(
          "[data-currency-view-name]:not([hidden]) [data-controller='performance-chart']"
        )
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "performance-chart")
        return controller.chart.data.datasets
          .filter((_, index) => controller.chart.isDatasetVisible(index))
          .map((dataset) => dataset.role)
      })()
    JAVASCRIPT
  end

  def chart_dataset_roles
    page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const element = document.querySelector(
          "[data-currency-view-name]:not([hidden]) [data-controller='performance-chart']"
        )
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "performance-chart")
        return controller.chart.data.datasets.map((dataset) => dataset.role)
      })()
    JAVASCRIPT
  end

  def select_chart_legend_item(label)
    page.execute_script(<<~JAVASCRIPT, label)
      (() => {
        const label = arguments[0]
        const element = document.querySelector(
          "[data-currency-view-name]:not([hidden]) [data-controller='performance-chart']"
        )
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "performance-chart")
        const item = controller.chart.legend.legendItems.find((legendItem) => legendItem.text === label)
        controller.chart.options.plugins.legend.onClick(null, item, controller.chart.legend)
      })()
    JAVASCRIPT
  end

  def current_query_parameters
    Rack::Utils.parse_query(URI.parse(page.current_url).query)
  end
end
