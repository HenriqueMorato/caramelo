require "application_system_test_case"

class PerformanceTest < ApplicationSystemTestCase
  test "selects a reporting period and shows performance" do
    Trade.where(user: User.owner).delete_all
    from = Date.current - 1.week
    instrument = Instrument.create!(ticker: "SYPR", exchange: "BVMF", name: "System performance stock", currency: "BRL")
    create_trade(instrument:, traded_on: from)
    create_trade(instrument:, traded_on: Date.current)
    create_daily_close(instrument:, date: from, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")
    Performance::ObservationBuilder.new(user: User.owner).call(from: Date.current - 1.month, to: Date.current)

    visit performance_path

    assert_text "How the pack is doing."
    assert_text "R$22,00"
    assert_selector "canvas[data-performance-chart-target='canvas']"
    assert_selector "th", text: "Net invested", visible: false
    click_on "Week"
    assert_current_path performance_path(period: "week")
    assert_text "20.00%"
  end

  test "shows a closed portfolio without requiring a current price" do
    Trade.where(user: User.owner).delete_all
    instrument = Instrument.create!(ticker: "SCLP", exchange: "BVMF", name: "Sold performance stock", currency: "BRL")
    create_trade(instrument:, traded_on: Date.current - 1.day, side: :buy)
    create_trade(instrument:, traded_on: Date.current, side: :sell)

    visit performance_path

    assert_text "How the pack is doing."
    assert_text "R$0,00"
    assert_no_text "Prices through"
  end

  test "recolors an existing chart without losing its data or selected view" do
    Trade.where(user: User.owner).delete_all
    from = Date.current - 1.week
    instrument = Instrument.create!(ticker: "THME", exchange: "BVMF", name: "Theme chart stock", currency: "BRL")
    create_trade(instrument:, traded_on: from)
    create_daily_close(instrument:, date: from, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")
    Performance::ObservationBuilder.new(user: User.owner).call(from:, to: Date.current)
    visit root_path
    page.execute_script("localStorage.removeItem('local_folio.appearance')")
    visit performance_path
    select_appearance("light")
    click_button "Performance"

    before = chart_state
    select_appearance("dark")
    after = chart_state

    assert_equal before.fetch("data"), after.fetch("data")
    assert_equal before.fetch("hidden"), after.fetch("hidden")
    assert_not_equal before.fetch("colors"), after.fetch("colors")
  end

  test "shows historical data loading while a missing price is being backfilled" do
    Trade.where(user: User.owner).delete_all
    instrument = Instrument.create!(ticker: "WAIT", exchange: "BVMF", name: "Pending performance stock", currency: "BRL")
    trade = create_trade(instrument:, traded_on: Date.current - 1.month)
    HistoricalDataBackfill.create!(instrument:, currency: trade.currency, from_date: trade.traded_on)

    visit performance_path

    assert_text "Historical data is loading"
    assert_text "Check back shortly"
  end

  test "shows background progress before a performance range is materialized" do
    Trade.where(user: User.owner).delete_all
    instrument = Instrument.create!(ticker: "ASYNC", exchange: "BVMF", name: "Async performance stock", currency: "BRL")
    create_trade(instrument:, traded_on: Date.current - 1.month)
    create_daily_close(instrument:, date: Date.current - 1.month, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")

    visit performance_path

    assert_text "Portfolio history is building"
    assert_text "preparing exact daily values in the background"
  end

  private

  def create_trade(instrument:, traded_on:, side: :buy)
    User.owner.trades.create!(
      instrument:, side:, traded_on:, quantity: 1, unit_price: "10", fees_cents: 0, currency: "BRL"
    )
  end

  def create_daily_close(instrument:, date:, close_price:)
    DailyClosingPrice.create!(
      instrument:, trading_date: date, close_price:, currency: "BRL", provider: "yahoo_finance", observed_at: Time.current
    )
  end

  def chart_state
    page.evaluate_script(<<~JS)
      (() => {
        const element = document.querySelector("[data-controller='performance-chart']")
        const chart = window.Stimulus.getControllerForElementAndIdentifier(element, "performance-chart").chart
        return {
          data: chart.data.datasets.map((dataset) => dataset.data),
          hidden: chart.data.datasets.map((_, index) => chart.isDatasetVisible(index)),
          colors: chart.data.datasets.map((dataset) => dataset.borderColor)
        }
      })()
    JS
  end

  def select_appearance(mode)
    page.execute_script("document.querySelector('[data-appearance-mode=\"#{mode}\"]').click()")
    assert_selector "html[data-appearance='#{mode}']", visible: :all
  end
end
