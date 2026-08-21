require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test "renders the public dashboard for the configured owner" do
    get root_url

    assert_response :success
    assert_select "h1", "Dashboard"
  end
end
