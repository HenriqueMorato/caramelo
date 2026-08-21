require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "allows unauthenticated visitors to access the application" do
    get root_url

    assert_response :success
    assert_select "h1", "LocalFolio"
  end

  test "allows authenticated users to access the application" do
    sign_in_as users(:one)

    get root_url

    assert_response :success
  end
end
