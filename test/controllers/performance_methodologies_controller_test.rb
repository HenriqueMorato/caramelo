require "test_helper"

class PerformanceMethodologiesControllerTest < ActionDispatch::IntegrationTest
  test "explains both return methodologies with a worked example" do
    get performance_methodology_url

    assert_response :success
    assert_select "title", "Return methodology · caramelo"
    assert_select "h1", "How caramelo calculates returns"
    assert_select "#modified-dietz-heading", "Modified Dietz"
    assert_select "#gain-on-cost-heading", "Gain on cost"
    assert_includes response.body, "46.15%"
    assert_includes response.body, "25.00%"
    assert_select "a[href=?]", performance_path, "View portfolio performance"
    assert_select "a[href=?]", positions_path, "View positions"
  end
end
