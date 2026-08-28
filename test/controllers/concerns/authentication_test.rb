require "test_helper"

class AuthenticationTestController < ActionController::Base
  include Authentication

  def show
    render plain: authenticated? ? "true" : "false"
  end
end

class AuthenticationTest < ActionController::TestCase
  tests AuthenticationTestController

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw { get "show", to: "authentication_test#show" }
  end

  test "authenticated helper resumes a signed session" do
    signed_session = users(:owner).sessions.create!
    cookies.signed[:session_id] = signed_session.id

    get :show

    assert_response :success
    assert_equal "true", response.body
  end
end
