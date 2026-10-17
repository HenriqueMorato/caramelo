require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_out
    @user = users(:owner)
  end

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "new explains terminal setup when the owner is unconfigured" do
    @user.update!(password_configured_at: nil)

    get new_session_path

    assert_response :success
    assert_select "[role=status]", /Set the first password from the terminal/
    assert_select "code", /bin\/caramelo-password setup/
  end

  test "does not expose a browser first-run setup route" do
    get "/account/setup"

    assert_response :not_found
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "retries a transient SQLite session write" do
    persisted_session = Session.create!(user: @user)
    attempts = 0
    sessions = Object.new
    sessions.define_singleton_method(:create!) do |**|
      attempts += 1
      raise ActiveRecord::StatementTimeout, "database is locked" if attempts == 1

      persisted_session
    end

    sessions_method = @user.method(:sessions)
    @user.singleton_class.define_method(:sessions, -> { sessions })
    controller = SessionsController.new
    controller.set_request!(ActionDispatch::TestRequest.create)

    assert_equal persisted_session, controller.send(:create_session_with_retry, @user)
    assert_equal 2, attempts
  ensure
    @user.singleton_class.define_method(:sessions, sessions_method) if sessions_method
  end

  test "create normalizes the email address" do
    post session_path, params: { email_address: "  #{@user.email_address.upcase} ", password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "create with invalid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "create rejects a user whose password setup is incomplete" do
    @user.update!(password_configured_at: nil)

    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to new_session_path
    assert_equal I18n.t("alerts.Invalid credentials"), flash[:alert]
  end

  test "current_user is empty without a session" do
    controller = SessionsController.new
    controller.set_request!(ActionDispatch::TestRequest.create)
    Current.session = nil

    assert_nil controller.send(:current_user)
  ensure
    Current.session = nil
  end

  test "single-account current_account can represent an unpersisted owner before terminal setup" do
    configured_email = Rails.application.config.x.caramelo.owner_email
    Rails.application.config.x.caramelo.owner_email = "new-owner@example.com"
    controller = SessionsController.new

    assert_not_predicate controller.send(:current_account), :persisted?
  ensure
    Rails.application.config.x.caramelo.owner_email = configured_email
  end

  test "does not retry a non-lock SQLite session error" do
    sessions = Object.new
    sessions.define_singleton_method(:create!) do |**|
      raise ActiveRecord::StatementTimeout, "database unavailable"
    end
    sessions_method = @user.method(:sessions)
    @user.singleton_class.define_method(:sessions, -> { sessions })
    controller = SessionsController.new
    controller.set_request!(ActionDispatch::TestRequest.create)

    assert_raises(ActiveRecord::StatementTimeout) do
      controller.send(:create_session_with_retry, @user)
    end
  ensure
    @user.singleton_class.define_method(:sessions, sessions_method) if sessions_method
  end

  test "protected pages redirect to sign in when the owner is configured" do
    get root_path

    assert_redirected_to new_session_path
    assert_equal root_url, session[:return_to_after_authenticating]
  end

  test "protected pages redirect to terminal setup instructions when the owner is unconfigured" do
    @user.update!(password_configured_at: nil)

    get root_path

    assert_redirected_to new_session_path
    assert_equal root_url, session[:return_to_after_authenticating]
  end

  test "single mode does not allow another user's credentials" do
    post session_path, params: { email_address: users(:one).email_address, password: "password" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "treats credentials as invalid when the configured owner is missing" do
    configured_email = Rails.application.config.x.caramelo.owner_email
    Rails.application.config.x.caramelo.owner_email = "missing-owner@example.com"

    post session_path, params: { email_address: users(:one).email_address, password: "password" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  ensure
    Rails.application.config.x.caramelo.owner_email = configured_email
  end

  test "destroy" do
    sign_in_as(User.take)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
  end

  test "destroy without a session is safe in public single-account mode" do
    previous = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.authentication_mode = "public"
    sign_out

    delete session_path

    assert_redirected_to new_session_path
  ensure
    Rails.application.config.x.caramelo.authentication_mode = previous
  end

  test "destroy clears the session when cable disconnect fails" do
    sign_in_as(@user)
    session = Current.session
    original = ApplicationCable::Connection.method(:disconnect_user)
    ApplicationCable::Connection.define_singleton_method(:disconnect_user) do |user|
      raise "cable unavailable for #{user.id}"
    end

    delete session_path

    assert_redirected_to new_session_path
    assert_not Session.exists?(session.id)
    assert_empty cookies[:session_id]
  ensure
    ApplicationCable::Connection.define_singleton_method(:disconnect_user, original) if original
  end

  test "destroy requires an authenticated session" do
    delete session_path

    assert_redirected_to new_session_path
    assert_equal session_url, session[:return_to_after_authenticating]
  end
end
