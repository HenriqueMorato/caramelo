require "test_helper"

class MoneyVisibilitiesControllerTest < ActionDispatch::IntegrationTest
  test "hides money server-side and keeps the choice across navigation" do
    patch money_visibility_url, params: { hidden: "true" }, headers: { "HTTP_REFERER" => transactions_url }

    assert_redirected_to transactions_url

    get transactions_url

    assert_response :success
    assert_select "button[aria-label='Show monetary values'][aria-pressed='true']", count: 2
    assert_select ".sr-only", text: "Monetary value hidden", minimum: 1
    assert_select "body", text: /\$611\.20/, count: 0

    get positions_url

    assert_response :success
    assert_select "button[aria-label='Show monetary values'][aria-pressed='true']", count: 2
  end

  test "prevents Turbo from restoring a stale visible-money snapshot" do
    get root_url

    assert_response :success
    assert_select "meta[name='turbo-cache-control'][content='no-cache']", count: 1
  end

  test "reveals money again from the same session" do
    patch money_visibility_url, params: { hidden: "true" }
    patch money_visibility_url, params: { hidden: "false" }, headers: { "HTTP_REFERER" => transactions_url }

    assert_redirected_to transactions_url

    get transactions_url

    assert_select "button[aria-label='Hide monetary values'][aria-pressed='false']", count: 2
    assert_select "body", text: /\$611\.20/
  end

  test "rejects an unsupported visibility value" do
    patch money_visibility_url, params: { hidden: "sometimes" }

    assert_response :bad_request
  end

  test "does not render a financial edit form while values are hidden" do
    patch money_visibility_url, params: { hidden: "true" }

    edit_url = edit_trade_url(trades(:owner_voo_buy))
    get edit_url, headers: { "HTTP_REFERER" => edit_url }

    assert_redirected_to root_url
    assert_equal "Show monetary values before editing transactions, income, or exporting data.", flash[:alert]
  end
end
