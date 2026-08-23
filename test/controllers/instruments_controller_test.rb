require "test_helper"

class InstrumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @instrument = instruments(:petr4_bvmf)
  end

  test "lists the global instrument catalog" do
    get instruments_url

    assert_response :success
    assert_select "h1", "Instruments"
    assert_select "h2", text: instruments(:petr4_bvmf).ticker
    assert_select "h2", text: instruments(:voo_arcx).ticker
  end

  test "shows an instrument with its future trade history area" do
    get instrument_url(@instrument)

    assert_response :success
    assert_select "h1", @instrument.ticker
    assert_select "h2", "Trade history"
    assert_select "p", "No trades for this instrument"
  end

  test "shows only the configured owner's trades for an instrument" do
    instrument = instruments(:voo_arcx)

    get instrument_url(instrument)

    assert_response :success
    assert_select "article", text: /Long-term allocation/
    assert_select "article", text: /Other owner trade/, count: 0
    assert_select "a", "Add trade"
    assert_select "button[disabled]", "Delete"
    assert_select "[role='tooltip']", "Delete this instrument's trades before deleting the instrument."
    assert_select "[aria-describedby='delete_tooltip_instrument_#{instrument.id}']"
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
end
