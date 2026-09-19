require "test_helper"

class TradeExportsControllerTest < ActionDispatch::IntegrationTest
  test "downloads an owner-scoped CSV attachment" do
    get trade_export_url(format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.headers.fetch("Content-Type"), "charset=utf-8"
    assert_includes response.headers.fetch("Content-Disposition"), "caramelo-trades-"
    assert_includes response.body, "trade_id,traded_on,side"
    refute_includes response.body, "Other owner trade."
  end

  test "does not send financial data while money values are hidden" do
    patch money_visibility_url, params: { hidden: "true" }

    get trade_export_url(format: :csv)

    assert_redirected_to root_url
    assert_equal "Show monetary values before editing transactions, income, or exporting data.", flash[:alert]
    refute_equal "text/csv", response.media_type
  end
end
