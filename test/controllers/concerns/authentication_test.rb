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

  test "clears a session whose password is no longer configured" do
    previous = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.authentication_mode = "public"
    user = users(:owner)
    signed_session = user.sessions.create!
    cookies.signed[:session_id] = signed_session.id
    user.update!(password_configured_at: nil)

    get :show

    assert_response :success
    assert_equal "false", response.body
    assert_nil cookies[:session_id]
    assert_nil Current.session
  ensure
    Rails.application.config.x.caramelo.authentication_mode = previous
  end

  test "public single-account mode does not require a session" do
    previous = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.authentication_mode = "public"

    get :show

    assert_response :success
    assert_equal "false", response.body
    assert_nil @controller.send(:current_user)
    assert_predicate @controller, :public_access?
    assert_not @controller.send(:password_setup_required?)
  ensure
    Rails.application.config.x.caramelo.authentication_mode = previous
  end

  test "current account follows the signed-in user in multi-account mode" do
    previous = Rails.application.config.x.caramelo.account_mode
    Rails.application.config.x.caramelo.account_mode = "multi"
    signed_session = users(:one).sessions.create!
    cookies.signed[:session_id] = signed_session.id

    get :show

    assert_response :success
    assert_equal users(:one), @controller.send(:current_account)
  ensure
    Rails.application.config.x.caramelo.account_mode = previous
  end
end
