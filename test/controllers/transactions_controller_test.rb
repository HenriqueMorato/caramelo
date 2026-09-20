require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    CorporateAction.delete_all
    @trade = trades(:owner_voo_buy)
    @income = create_income
  end

  test "lists owner trades and income together in reverse chronological order" do
    create_income(user: users(:one), institution: institutions(:other_owner), source_reference: "other")

    get transactions_url

    assert_response :success
    assert_select "h1", "The trail behind the pack."
    assert_select "details[data-testid='add-transaction-menu'] summary", text: /Add/
    assert_select "a[href='#{new_trade_path}']", text: /Trade/
    assert_select "a[href='#{new_corporate_action_path}']", text: /Income/
    assert_select "tr##{dom_id(@trade)}"
    assert_select "tr##{dom_id(@income)}" do
      assert_select "a[href=?]", instrument_path(@income.instrument), @income.instrument.name
      assert_select "a[href=?]", edit_corporate_action_path(@income), "Edit"
      assert_select "form[action=?] button", corporate_action_path(@income), "Delete"
    end
    assert_select "tr", text: /Other owner trade/, count: 0
    assert_equal [ dom_id(@income), dom_id(@trade) ], transaction_row_ids
  end

  test "filters the combined history through URL-backed activity links" do
    get transactions_url(activity: "trades")

    assert_response :success
    assert_select "a[aria-current='page']", "Trades"
    assert_select "tr##{dom_id(@trade)}"
    assert_select "tr##{dom_id(@income)}", count: 0

    get transactions_url(activity: "income")

    assert_response :success
    assert_select "a[aria-current='page']", "Income"
    assert_select "tr##{dom_id(@trade)}", count: 0
    assert_select "tr##{dom_id(@income)}"
  end

  test "keeps filters visible when the selected activity has no matches" do
    CorporateAction.delete_all

    get transactions_url(activity: "income")

    assert_response :success
    assert_select "a[aria-current='page']", "Income"
    assert_select "tbody td", "No activity matches this filter."
  end

  test "ignores an unsupported activity filter" do
    get transactions_url(activity: "interest")

    assert_response :success
    assert_select "tr##{dom_id(@trade)}"
    assert_select "tr##{dom_id(@income)}"
    assert_select "a[aria-current='page'][href='#{transactions_path}']", "All"
  end

  test "renders one empty state when there are no trades or income" do
    Trade.where(user: User.owner).delete_all
    CorporateAction.where(user: User.owner).delete_all

    get transactions_url

    assert_response :success
    assert_select "p", "No activity yet"
    assert_select "details[data-testid='add-transaction-menu'] summary", text: /Add/
  end

  test "does not expose a separate income index route" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/income")
    end
  end

  private

  def transaction_row_ids
    response.parsed_body.css("tbody > tr").filter_map { |row| row["id"] }
  end

  def create_income(user: users(:owner), institution: institutions(:owner_xp), source_reference: nil)
    CorporateAction.create!(
      user:, instrument: instruments(:petr4_bvmf), institution:, kind: :dividend,
      status: :confirmed, paid_on: Date.new(2026, 8, 25), gross_amount_cents: 1_234,
      withholding_tax_cents: 185, net_amount_cents: 1_049, currency: "BRL",
      source: "manual", source_reference:
    )
  end
end
