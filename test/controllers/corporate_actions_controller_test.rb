require "test_helper"

class CorporateActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    CorporateAction.delete_all
    @corporate_action = create_action
  end

  test "uses an opaque corporate-action reference in durable URLs" do
    assert_match %r{\A/corporate_actions/evt-[a-zA-Z0-9]{12}\z}, corporate_action_path(@corporate_action)
  end

  test "lists only the configured owner's income and supports URL filters" do
    create_action(user: users(:one), institution: institutions(:other_owner), source_reference: "other")

    get income_url(kind: "dividend")

    assert_response :success
    assert_select "h1", "Income earned along the way."
    assert_select "tr##{dom_id(@corporate_action)}"
    assert_select "a[aria-current='page']", "Dividends only"
    assert_select "tbody tr", count: 1
  end

  test "keeps filters visible when nothing matches and ignores unknown filters" do
    get income_url(kind: "jcp")
    assert_response :success
    assert_select "tbody td", "No income events match this filter."

    get income_url(kind: "interest")
    assert_response :success
    assert_select "tr##{dom_id(@corporate_action)}"
    assert_select "a[aria-current='page'][href='#{income_path}']", "All income"
  end

  test "renders an empty state" do
    CorporateAction.delete_all

    get income_url

    assert_response :success
    assert_select "p", "No income yet"
  end

  test "new income offers instruments and keeps derived fields out of the form" do
    get new_corporate_action_url

    assert_response :success
    assert_select "option", text: /PETR4/
    assert_select "option", text: /VOO/
    assert_not_includes response.body, institutions(:owner_xp).name
    assert_not_includes response.body, institutions(:other_owner).name
    assert_select "option[value='dividend'][selected]"
    assert_select "input[name='corporate_action[currency]']", count: 0
    assert_select "[data-controller='income-form']"
  end

  test "new contextual income fixes the instrument and submits its sole institution invisibly" do
    instrument = instruments(:voo_arcx)
    recent_trade = trades(:owner_voo_buy).dup
    recent_trade.institution = institutions(:owner_xp)
    recent_trade.save!

    get new_instrument_corporate_action_url(instrument)

    assert_response :success
    assert_select "select[name='corporate_action[instrument_id]']", count: 0
    assert_select "input[type='hidden'][name='corporate_action[instrument_id]'][value='#{instrument.id}']"
    assert_select "input[type='hidden'][name='corporate_action[institution_id]'][value='#{institutions(:owner_xp).id}']:not([disabled])"
    assert_select "select[name='corporate_action[institution_id]']:not([disabled])", count: 0
    assert_select "select[name='corporate_action[kind]']:not([disabled])", count: 0
  end

  test "creates owner income and derives currency net amount and provenance" do
    assert_difference("User.owner.corporate_actions.count") do
      post corporate_actions_url, params: {
        corporate_action: valid_params.merge(
          user_id: users(:one).id, currency: "USD", status: "pending", source: "provider"
        )
      }
    end

    action = CorporateAction.order(:id).last
    assert_redirected_to income_url
    assert_equal User.owner, action.user
    assert_equal "BRL", action.currency
    assert_equal 1_234, action.gross_amount_cents
    assert_equal 185, action.withholding_tax_cents
    assert_equal 1_049, action.net_amount_cents
    assert_equal "confirmed", action.status
    assert_equal "manual", action.source
    assert_equal Date.new(2026, 8, 20), action.ex_date
    assert_equal Date.new(2026, 8, 20), HistoricalDataBackfill.find_by!(
      instrument: action.instrument, currency: action.currency
    ).from_date
  end

  test "contextual creation cannot be redirected to another instrument" do
    context = instruments(:voo_arcx)

    assert_difference("User.owner.corporate_actions.count") do
      post instrument_corporate_actions_url(context), params: {
        corporate_action: valid_params.merge(instrument_id: instruments(:petr4_bvmf).id)
      }
    end

    assert_equal context, CorporateAction.order(:id).last.instrument
  end

  test "renders validation errors without accepting a negative withholding" do
    assert_no_difference("CorporateAction.count") do
      post corporate_actions_url, params: {
        corporate_action: valid_params.merge(withholding_tax: "-1")
      }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Withholding tax must be greater than or equal to 0/
    assert_select "input[name='corporate_action[withholding_tax]'][value='-1.0']"
  end

  test "renders malformed monetary input as validation errors" do
    assert_no_difference("CorporateAction.count") do
      post corporate_actions_url, params: {
        corporate_action: valid_params.merge(gross_amount: "not a number")
      }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Gross amount is not a number/
  end

  test "shows and updates owner income while rejecting another owner's record" do
    get corporate_action_url(@corporate_action)
    assert_response :success
    assert_select "h1", /PETR4/

    trade = trades(:owner_voo_buy).dup
    trade.instrument = @corporate_action.instrument
    trade.institution = @corporate_action.institution
    trade.currency = @corporate_action.currency
    trade.slug = nil
    trade.save!

    patch corporate_action_url(@corporate_action), params: {
      corporate_action: valid_params.merge(kind: "jcp", gross_amount: "20", withholding_tax: "3")
    }
    assert_redirected_to income_url
    assert_equal "jcp", @corporate_action.reload.kind
    assert_equal 1_700, @corporate_action.net_amount_cents

    other = create_action(user: users(:one), institution: institutions(:other_owner), source_reference: "private")
    get edit_corporate_action_url(other)
    assert_response :not_found
  end

  test "renders update errors when the instrument and amounts are invalid" do
    patch corporate_action_url(@corporate_action), params: {
      corporate_action: valid_params.merge(instrument_id: "", gross_amount: "not a number")
    }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Instrument must exist/
    assert_select "[role=alert]", /Gross amount is not a number/
  end

  test "deletes owner income" do
    assert_difference("CorporateAction.count", -1) do
      delete corporate_action_url(@corporate_action)
    end

    assert_redirected_to income_url
  end

  test "privacy mode masks read pages and blocks money-editing routes" do
    patch money_visibility_url, params: { hidden: "true", return_to: income_path }

    get income_url
    assert_response :success
    assert_select "body", text: /#{Regexp.escape(ApplicationHelper::MONEY_MASK)}/
    assert_select "body", text: /R\$10,49/, count: 0

    get new_corporate_action_url
    assert_redirected_to root_url
  end

  private

  def valid_params
    {
      instrument_id: instruments(:petr4_bvmf).id,
      institution_id: institutions(:owner_xp).id,
      kind: "dividend",
      paid_on: "2026-08-25",
      ex_date: "2026-08-20",
      gross_amount: "12.34",
      withholding_tax: "1.85",
      notes: "Quarterly payout"
    }
  end

  def create_action(user: users(:owner), institution: institutions(:owner_xp), source_reference: nil)
    CorporateAction.create!(
      user:, instrument: instruments(:petr4_bvmf), institution:, kind: :dividend,
      status: :confirmed, paid_on: Date.new(2026, 8, 25), gross_amount_cents: 1_234,
      withholding_tax_cents: 185, net_amount_cents: 1_049, currency: "BRL",
      source: "manual", source_reference:
    )
  end
end
