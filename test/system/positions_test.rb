require "application_system_test_case"

class PositionsTest < ApplicationSystemTestCase
  setup do
    page.current_window.resize_to(390, 844)
  end

  test "shows an open position on a mobile viewport" do
    visit positions_path

    assert_text "Your little pack."
    assert_text "VOO"
    assert_text "ARCX"
    assert_text "Vanguard S&P 500 ETF"
    assert_text "2.5"
    assert_text "$611.60"
    assert_text "$1,529.00"
    assert_text "USD"

    click_on "VOO"

    assert_current_path instrument_path(instruments(:voo_arcx))
  end

  test "shows allocation charts below the positions list" do
    instrument = Instrument.find_by!(ticker: "VOO")
    write_current_market_price(instrument:, unit_price: "611.60")
    write_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5")

    visit positions_path

    assert_text "How the portfolio is divided."
    assert_text "By type"
    assert_text "By position"
    assert_selector "[data-controller='allocation-chart']", count: 2
    assert_selector "summary", text: "View exact values", count: 2

    page.document.synchronize do
      ready = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("[data-controller='allocation-chart']")].every((element) => {
          const chart = window.Stimulus.getControllerForElementAndIdentifier(element, "allocation-chart")?.chart
          return Boolean(chart?.data?.datasets?.length)
        })
      JS
      raise Capybara::ElementNotFound, "allocation charts are not ready" unless ready
    end

    chart_data = page.evaluate_script(<<~JS)
      (() => [...document.querySelectorAll("[data-controller='allocation-chart']")].map((element) => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "allocation-chart")
        return controller.chart.data
      }))()
    JS

    assert_equal [ "Other" ], chart_data.fetch(0).fetch("labels")
    assert_equal [ "VOO" ], chart_data.fetch(1).fetch("labels")
  end

  test "chooses nested grouping options and can clear grouping" do
    visit positions_path

    click_button "Type"
    assert_text "OTHER"
    assert_selector "button.grouping-option[data-grouping-value='asset_type'][aria-pressed='true'][data-grouping-slot='primary']"
    assert_selector "button.grouping-option[data-grouping-value='currency'][aria-pressed='false'][data-grouping-slot='']"

    click_button "Currency"
    assert_text "USD"
    assert_selector "button.grouping-option[data-grouping-value='currency'][aria-pressed='true'][data-grouping-slot='secondary']"

    click_button "Type"
    assert_selector "button.grouping-option[data-grouping-value='currency'][aria-pressed='true'][data-grouping-slot='primary']"
    assert_selector "button.grouping-option[data-grouping-value='asset_type'][aria-pressed='false'][data-grouping-slot='']"

    click_button "Clear"
    assert_selector "button.grouping-option[data-grouping-value='asset_type'][aria-pressed='false'][data-grouping-slot='']"
    assert_text "POSITION"
  end

  test "includes a closed position when requested" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy)
    create_trade(instrument:, side: :sell, traded_on: Date.new(2026, 1, 2))

    visit positions_path

    assert_no_text "PETR4"
    click_on "Include closed positions"

    assert_current_path positions_path(closed: 1)
    assert_text "PETR4"
    assert_text "BVMF"
    assert_text "Closed"
  end

  test "shows an unavailable B3 price without a refresh control" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy)

    visit positions_path

    within "#current_market_price_instrument_#{instrument.id}" do
      assert_text "Price unavailable"
      assert_no_button "Refresh"
    end
  end

  test "shows the empty state on a desktop viewport" do
    page.current_window.resize_to(1280, 900)
    Trade.where(user: User.owner).delete_all

    visit positions_path

    assert_text "No positions yet"
    assert_link "Add trade"
  end

  private

  def create_trade(instrument:, side:, traded_on: Date.new(2026, 1, 1))
    User.owner.trades.create!(
      instrument:,
      side:,
      traded_on:,
      quantity: 1,
      unit_price: 10,
      fees_cents: 0,
      currency: instrument.currency
    )
  end

  def write_current_market_price(instrument:, unit_price:)
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price:, currency: instrument.currency, provider: "yahoo_finance",
        quoted_at: Time.current - 1.minute, fetched_at: Time.current
      )
    )
  end

  def write_exchange_rate(base_currency:, quote_currency:, rate:)
    ExchangeRateCache.new.write(
      exchange_rate: ExchangeRate::Rate.new(
        base_currency:, quote_currency:, rate: BigDecimal(rate), provider: "yahoo_finance_fx",
        observed_at: Time.current - 1.minute, fetched_at: Time.current
      )
    )
  end
end
