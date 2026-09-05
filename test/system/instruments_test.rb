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
    assert_text "XNAS"
    assert_text "Apple Inc."
    assert_text "USD"
    assert_text "Trade history"
  end

  test "edits an instrument" do
    instrument = instruments(:petr4_bvmf)

    visit edit_instrument_path(instrument)
    fill_in "Ticker", with: "petr3"
    fill_in "Name", with: "Petrobras ON"
    click_on "Update Instrument"

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
    assert_selector "##{tooltip_id}", text: "Delete this instrument's trades before deleting the instrument.", visible: true
  end

  test "updates an instrument position after contextual trade changes" do
    instrument = instruments(:petr4_bvmf)

    visit instrument_path(instrument)

    assert_text "No trades"
    within "[aria-labelledby='trade-history-heading']" do
      assert_link "Add trade"
    end
    within "[aria-labelledby='position-summary-heading']" do
      click_on "Add trade"
    end

    fill_in "Trade date", with: "2026-08-24"
    fill_in "Quantity", with: "3"
    fill_in "Unit price", with: "20"
    fill_in "Fees", with: "0"
    click_on "Create Trade"

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

    visit instrument_path(instrument)
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

    visit instrument_path(instrument)
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

    within "[aria-labelledby='instrument-performance-heading']" do
      assert_text "$400.00"
      click_on "BRL · My currency"
      assert_text "R$2.100,00"
    end
    assert_current_path instrument_path(instrument, currency_view: "reporting")

    refresh

    within "[aria-labelledby='instrument-performance-heading']" do
      assert_text "R$2.100,00"
      assert_no_text "$400.00"
    end

    page.go_back

    within "[aria-labelledby='instrument-performance-heading']" do
      assert_text "$400.00"
      assert_no_text "R$2.100,00"
    end
  end
end
