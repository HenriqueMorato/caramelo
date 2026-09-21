require "test_helper"

class CorporateActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    CorporateAction.delete_all
    @corporate_action = create_action
  end

  test "uses an opaque corporate-action reference in durable URLs" do
    assert_match %r{\A/corporate_actions/evt-[a-zA-Z0-9]{12}\z}, corporate_action_path(@corporate_action)
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(corporate_action_path(@corporate_action), method: :get)
    end
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
    assert_redirected_to transactions_url
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

  test "updates owner income while rejecting another owner's record" do
    trade = trades(:owner_voo_buy).dup
    trade.instrument = @corporate_action.instrument
    trade.institution = @corporate_action.institution
    trade.currency = @corporate_action.currency
    trade.slug = nil
    trade.save!

    return_to = instrument_path(@corporate_action.instrument, activity: "income")
    patch corporate_action_url(@corporate_action), params: {
      return_to:,
      corporate_action: valid_params.merge(kind: "jcp", gross_amount: "20", withholding_tax: "3")
    }
    assert_redirected_to return_to
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
    return_to = instrument_url(@corporate_action.instrument, activity: "income")
    assert_difference("CorporateAction.count", -1) do
      delete corporate_action_url(@corporate_action), headers: { "HTTP_REFERER" => return_to }
    end

    assert_redirected_to return_to
  end

  test "edit preserves a safe return target and rejects an external one" do
    return_to = instrument_url(@corporate_action.instrument, activity: "income")

    get edit_corporate_action_url(@corporate_action), headers: { "HTTP_REFERER" => return_to }

    assert_response :success
    assert_select "input[type='hidden'][name='return_to'][value='#{return_to}']"
    assert_select "a[href='#{return_to}']", text: /Back/

    get edit_corporate_action_url(@corporate_action), headers: { "HTTP_REFERER" => "https://example.com/elsewhere" }

    assert_response :success
    assert_select "input[type='hidden'][name='return_to'][value='#{transactions_path}']"
    assert_select "a[href='#{transactions_path}']", text: /Back/
  end

  test "privacy mode masks read pages and blocks money-editing routes" do
    patch money_visibility_url, params: { hidden: "true", return_to: transactions_path }

    get transactions_url(activity: "income")
    assert_response :success
    assert_select "body", text: /#{Regexp.escape(ApplicationHelper::MONEY_MASK)}/
    assert_select "body", text: /R\$10,49/, count: 0

    get new_corporate_action_url
    assert_redirected_to root_url
  end

  test "privacy mode permits cash-free quantity actions but blocks cash in lieu" do
    cash_action = create_quantity_action(
      effective_on: Date.new(2026, 8, 19),
      cash_in_lieu_quantity: "0.5", cash_in_lieu_amount_cents: 1_000,
      currency: instruments(:petr4_bvmf).currency
    )
    patch money_visibility_url, params: { hidden: "true", return_to: transactions_path }

    get new_quantity_action_url
    assert_response :success

    assert_difference("CorporateAction.quantity_actions.count") do
      post quantity_actions_url, params: { corporate_action: quantity_params }
    end
    assert_redirected_to transactions_url

    assert_no_difference("CorporateAction.quantity_actions.count") do
      post quantity_actions_url, params: {
        corporate_action: quantity_params.merge(
          cash_in_lieu_quantity: "0.5", cash_in_lieu_amount: "10"
        )
      }
    end
    assert_redirected_to root_url

    get edit_quantity_action_url(cash_action)
    assert_redirected_to root_url

    patch quantity_action_url(cash_action), params: {
      corporate_action: quantity_params.merge(cash_in_lieu_amount: "")
    }
    assert_redirected_to root_url
  end

  test "new quantity action explains the exact ratio and offers supported kinds" do
    get new_quantity_action_url

    assert_response :success
    assert_select "option[value='stock_split'][selected]"
    assert_select "option[value='reverse_split']"
    assert_select "option[value='share_bonus']"
    assert_select "input[name='corporate_action[ratio_numerator]'][value='2']"
    assert_select "input[name='corporate_action[ratio_denominator]'][value='1']"
    assert_select "input[name='corporate_action[cash_in_lieu_quantity]'][step='0.1']"
    assert_select "button[formnovalidate]", text: /Save quantity action/
    assert_select "[data-controller~='form-state']"
    assert_select "[data-controller~='institution-picker']"
    assert_select "[data-controller~='quantity-action-form']"
  end

  test "creates and edits a share bonus using percentage rather than ratio inputs" do
    assert_difference("CorporateAction.quantity_actions.count") do
      post quantity_actions_url, params: {
        corporate_action: quantity_params.merge(
          kind: "share_bonus", bonus_percentage: "2.5",
          ratio_numerator: "99", ratio_denominator: "1"
        )
      }
    end

    action = CorporateAction.quantity_actions.order(:id).last
    assert_equal [ 41, 40 ], [ action.ratio_numerator, action.ratio_denominator ]

    get edit_quantity_action_url(action)
    assert_select "input[name='corporate_action[bonus_percentage]'][value='2.5']"
    assert_select "input[name='corporate_action[ratio_numerator]'][disabled]"

    patch quantity_action_url(action), params: {
      corporate_action: quantity_params.merge(kind: "share_bonus", bonus_percentage: "10")
    }
    assert_redirected_to transactions_url
    assert_equal [ 11, 10 ], [ action.reload.ratio_numerator, action.ratio_denominator ]
  end

  test "shows invalid share bonus percentage beside the submitted value" do
    assert_no_difference("CorporateAction.count") do
      post quantity_actions_url, params: {
        corporate_action: quantity_params.merge(kind: "share_bonus", bonus_percentage: "NaN")
      }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Bonus percentage must be a positive, finite number/
    assert_select "input[name='corporate_action[bonus_percentage]'][value='NaN']"
  end

  test "creates a contextual quantity action with optional cash in lieu" do
    instrument = instruments(:petr4_bvmf)

    assert_difference("User.owner.corporate_actions.quantity_actions.count") do
      post instrument_quantity_actions_url(instrument), params: {
        corporate_action: quantity_params.merge(
          instrument_id: instruments(:voo_arcx).id,
          cash_in_lieu_quantity: "0.5",
          cash_in_lieu_amount: "12.34"
        )
      }
    end

    action = CorporateAction.order(:id).last
    assert_redirected_to transactions_url
    assert_equal instrument, action.instrument
    assert_equal "reverse_split", action.kind
    assert_equal Date.new(2026, 8, 20), action.effective_on
    assert_equal BigDecimal("0.5"), action.cash_in_lieu_quantity
    assert_equal Money.from_amount(BigDecimal("12.34"), "BRL"), action.cash_in_lieu_amount
    assert_equal instrument.currency, action.currency
  end

  test "creates a cash-free quantity action without inventing a currency" do
    assert_difference("CorporateAction.quantity_actions.count") do
      post quantity_actions_url, params: { corporate_action: quantity_params }
    end

    action = CorporateAction.order(:id).last
    assert_nil action.currency
    assert_nil action.cash_in_lieu_amount_cents
  end

  test "renders quantity validation errors and preserves the entered ratio" do
    assert_no_difference("CorporateAction.count") do
      post quantity_actions_url, params: {
        corporate_action: quantity_params.merge(ratio_numerator: "10", ratio_denominator: "1")
      }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /must be less than old shares/
    assert_select "input[name='corporate_action[ratio_numerator]'][value='10']"
  end

  test "renders malformed cash-in-lieu input as a validation error" do
    [ "not a number", "NaN", "Infinity", "-Infinity" ].each do |amount|
      assert_no_difference("CorporateAction.count") do
        post quantity_actions_url, params: {
          corporate_action: quantity_params.merge(
            cash_in_lieu_quantity: "0.5", cash_in_lieu_amount: amount
          )
        }
      end

      assert_response :unprocessable_content
      assert_select "[role=alert]", /Cash received is not a number/
      assert_select "input[name='corporate_action[cash_in_lieu_amount]'][value='#{amount}']"
    end
  end

  test "updates a quantity action and keeps income edit routes type safe" do
    action = create_quantity_action
    return_to = instrument_path(action.instrument, activity: "actions")

    get edit_quantity_action_url(action), headers: { "HTTP_REFERER" => return_to }
    assert_response :success

    patch quantity_action_url(action), params: {
      return_to:,
      corporate_action: quantity_params.merge(ratio_denominator: "5")
    }

    assert_redirected_to return_to
    assert_equal 5, action.reload.ratio_denominator

    get edit_corporate_action_url(action)
    assert_response :not_found
    get edit_quantity_action_url(@corporate_action)
    assert_response :not_found

    patch corporate_action_url(action), params: { corporate_action: valid_params }
    assert_response :not_found
    patch quantity_action_url(@corporate_action), params: { corporate_action: quantity_params }
    assert_response :not_found
  end

  test "renders quantity update errors" do
    action = create_quantity_action

    patch quantity_action_url(action), params: {
      corporate_action: quantity_params.merge(ratio_numerator: "0")
    }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /New shares must be greater than 0/
  end

  test "renders a missing-instrument cash-in-lieu error without deriving a currency" do
    assert_no_difference("CorporateAction.count") do
      post quantity_actions_url, params: {
        corporate_action: quantity_params.merge(
          instrument_id: "", cash_in_lieu_quantity: "0.5", cash_in_lieu_amount: "1"
        )
      }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Instrument must exist/

    assert_no_difference("CorporateAction.count") do
      post quantity_actions_url, params: {
        corporate_action: quantity_params.merge(
          instrument_id: "", cash_in_lieu_quantity: "0.5", cash_in_lieu_amount: "NaN"
        )
      }
    end
    assert_response :unprocessable_content
    assert_select "[role=alert]", /Cash received is not a number/
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

  def quantity_params
    {
      instrument_id: instruments(:petr4_bvmf).id,
      institution_id: institutions(:owner_xp).id,
      kind: "reverse_split",
      effective_on: "2026-08-20",
      ratio_numerator: "1",
      ratio_denominator: "10",
      cash_in_lieu_quantity: "",
      cash_in_lieu_amount: "",
      notes: "One new share for ten old shares"
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

  def create_quantity_action(**attributes)
    CorporateAction.create!({
      user: users(:owner), instrument: instruments(:petr4_bvmf),
      kind: :reverse_split, status: :confirmed, effective_on: Date.new(2026, 8, 20),
      ratio_numerator: 1, ratio_denominator: 10, source: "manual"
    }.merge(attributes))
  end
end
