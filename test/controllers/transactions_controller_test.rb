require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  test "renders the public transactions placeholder for the configured owner" do
    get transactions_url

    assert_response :success
    assert_select "h1", "Transactions"
  end
end
