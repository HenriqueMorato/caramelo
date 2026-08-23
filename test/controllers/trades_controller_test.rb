require "test_helper"

class TradesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @trade = trades(:owner_voo_buy)
  end

  test "lists only the configured owner's trades" do
    get transactions_url

    assert_response :success
    assert_select "h1", "Transactions"
    assert_select "article", text: /Banco do Brasil.*Long-term allocation/m
    assert_select "a[href='#{edit_trade_path(@trade)}']", "Edit"
    assert_select "form[action='#{trade_path(@trade)}'] button", "Delete"
    assert_select "article", text: /Other owner trade/, count: 0
  end

  test "renders an empty state" do
    Trade.where(user: User.owner).delete_all

    get transactions_url

    assert_response :success
    assert_select "p", "No trades yet"
  end

  test "does not expose another owner's trade for editing" do
    get edit_trade_url(trades(:other_owner_voo_sell))

    assert_response :not_found
  end

  test "clears another owner's institution" do
    assert_difference("Trade.count") do
      post trades_url, params: {
        trade: valid_trade_params.merge(institution_id: institutions(:other_owner).id)
      }
    end

    assert_nil Trade.order(:id).last.institution_id
  end

  test "new global trade offers global instruments and active owner institutions" do
    get new_trade_url

    assert_response :success
    assert_select "option", text: /PETR4/
    assert_select "option", text: /VOO/
    assert_select "option", text: /#{Regexp.escape(institutions(:owner_xp).name)}/
    assert_select "option", text: /#{Regexp.escape(institutions(:owner_inactive).name)}/, count: 0
    assert_select "option", text: /#{Regexp.escape(institutions(:other_owner).name)}/, count: 0
    assert_select "option[value='buy'][selected]"
    assert_select "input[name='trade[quantity]'][step='any']"
  end

  test "new global trade does not default to an institution" do
    recent_trade = @trade.dup
    recent_trade.institution = institutions(:owner_xp)
    recent_trade.traded_on = Date.new(2026, 8, 20)
    recent_trade.save!

    get new_trade_url

    assert_response :success
    assert_select "select[name='trade[institution_id]'] option[selected]", count: 0
  end

  test "new global trade exposes each instrument's last active institution" do
    recent_trade = @trade.dup
    recent_trade.assign_attributes(instrument: instruments(:petr4_bvmf), institution: institutions(:owner_xp), currency: "BRL")
    recent_trade.save!

    get new_trade_url

    assert_response :success
    assert_select "option[value='#{instruments(:petr4_bvmf).id}'][data-last-institution-id='#{institutions(:owner_xp).id}']"
    assert_select "option[value='#{instruments(:voo_arcx).id}']:not([data-last-institution-id])"
  end

  test "new contextual trade fixes the instrument and its currency" do
    instrument = instruments(:voo_arcx)
    previous_trade = @trade.dup
    previous_trade.institution = institutions(:owner_xp)
    previous_trade.save!
    latest_institution = User.owner.institutions.create!(name: "BTG Pactual")
    latest_overall_trade = @trade.dup
    latest_overall_trade.assign_attributes(instrument: instruments(:petr4_bvmf), institution: latest_institution, currency: "BRL")
    latest_overall_trade.save!

    get new_instrument_trade_url(instrument)

    assert_response :success
    assert_select "select[name='trade[instrument_id]']", count: 0
    assert_select "input[type='hidden'][name='trade[instrument_id]'][value='#{instrument.id}']"
    assert_select "input[name='trade[currency]'][value='USD'][disabled]"
    assert_select "option[value='#{institutions(:owner_xp).id}'][selected]"
    assert_select "option[value='#{latest_institution.id}']:not([selected])"
    assert_select "p", text: /VOO/
  end

  test "new contextual trade does not fall back to another instrument's institution" do
    trade = @trade.dup
    trade.assign_attributes(instrument: instruments(:petr4_bvmf), institution: institutions(:owner_xp), currency: "BRL")
    trade.save!

    get new_instrument_trade_url(instruments(:voo_arcx))

    assert_response :success
    assert_select "select[name='trade[institution_id]'] option[selected]", count: 0
  end

  test "creates a global trade for the owner and derives currency" do
    assert_difference("User.owner.trades.count") do
      post trades_url, params: {
        trade: {
          user_id: users(:one).id,
          instrument_id: instruments(:petr4_bvmf).id,
          institution_id: institutions(:owner_xp).id,
          side: "buy",
          traded_on: "2026-08-20",
          quantity: "10.25",
          unit_price: "32.12345678",
          fees: "4.90",
          currency: "USD",
          notes: "New position"
        }
      }
    end

    trade = Trade.order(:id).last
    assert_redirected_to transactions_url
    assert_equal User.owner, trade.user
    assert_equal instruments(:petr4_bvmf), trade.instrument
    assert_equal institutions(:owner_xp), trade.institution
    assert_equal "BRL", trade.currency
    assert_equal BigDecimal("10.25"), trade.quantity
    assert_equal BigDecimal("32.12345678"), trade.unit_price
    assert_equal 490, trade.fees_cents
  end

  test "contextual creation cannot be redirected to another instrument" do
    context = instruments(:petr4_bvmf)

    assert_difference("User.owner.trades.count") do
      post instrument_trades_url(context), params: {
        trade: valid_trade_params.merge(instrument_id: instruments(:voo_arcx).id)
      }
    end

    assert_equal context, Trade.order(:id).last.instrument
  end

  test "renders validation errors and preserves entered values" do
    assert_no_difference("Trade.count") do
      post trades_url, params: {
        trade: valid_trade_params.merge(quantity: "0", unit_price: "0", fees: "-1")
      }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Quantity must be greater than 0/
    assert_select "[role=alert]", /Unit price must be greater than 0/
    assert_select "[role=alert]", /Fees must be greater than or equal to 0/
    assert_select "input[name='trade[quantity]'][value='0']"
  end

  test "renders an error when the global instrument is missing" do
    assert_no_difference("Trade.count") do
      post trades_url, params: {
        trade: valid_trade_params.merge(instrument_id: "")
      }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Instrument must exist/
  end

  test "edit includes the trade's inactive institution" do
    get edit_trade_url(@trade)

    assert_response :success
    assert_select "option[selected]", text: /#{Regexp.escape(institutions(:owner_inactive).name)}/
    assert_select "option", text: /#{Regexp.escape(institutions(:other_owner).name)}/, count: 0
  end

  test "updates an owner trade" do
    patch trade_url(@trade), params: {
      trade: valid_trade_params.merge(
        instrument_id: instruments(:petr4_bvmf).id,
        institution_id: institutions(:owner_xp).id,
        side: "sell",
        quantity: "3",
        unit_price: "35.10",
        fees: "3.50",
        notes: "Reduced position"
      )
    }

    assert_redirected_to transactions_url
    assert_equal "sell", @trade.reload.side
    assert_equal instruments(:petr4_bvmf), @trade.instrument
    assert_equal "BRL", @trade.currency
    assert_equal BigDecimal("35.10"), @trade.unit_price
    assert_equal "Reduced position", @trade.notes
  end

  test "deletes an owner trade" do
    assert_difference("Trade.count", -1) do
      delete trade_url(@trade)
    end

    assert_redirected_to transactions_url
  end

  private

  def valid_trade_params
    {
      instrument_id: instruments(:petr4_bvmf).id,
      institution_id: institutions(:owner_xp).id,
      side: "buy",
      traded_on: "2026-08-20",
      quantity: "10",
      unit_price: "32.45",
      fees: "4.90",
      notes: "Trade notes"
    }
  end
end
