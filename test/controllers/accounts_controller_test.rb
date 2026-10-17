require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  teardown do
    users(:owner).update_columns(
      password_digest: BCrypt::Password.create("password"),
      password_configured_at: Time.current
    )
    users(:one).update_columns(password_configured_at: Time.current)
    users(:two).update_columns(password_configured_at: Time.current)
    Rails.cache.clear
  end

  test "single mode does not expose account registration" do
    get new_account_path

    assert_redirected_to new_session_path
  end

  test "multi mode creates an account and signs it in" do
    with_account_mode("multi") do
      get new_account_path
      assert_response :success

      assert_difference("User.count") do
        post accounts_path, params: {
          user: {
            email_address: "new-wallet@example.com",
            password: "a proper password",
            password_confirmation: "a proper password"
          }
        }
      end

      new_user = User.find_by!(email_address: "new-wallet@example.com")
      assert_redirected_to root_path
      assert_predicate new_user, :password_configured?
      assert cookies[:session_id]
    end
  end

  test "multi mode reports duplicate account emails instead of raising" do
    with_account_mode("multi") do
      assert_no_difference("User.count") do
        post accounts_path, params: {
          user: {
            email_address: users(:owner).email_address.upcase,
            password: "a proper password",
            password_confirmation: "a proper password"
          }
        }
      end

      assert_response :unprocessable_content
      assert_select "[role=alert]", /Email address has already been taken/
    end
  end

  test "multi mode renders a validation error when account creation races" do
    with_account_mode("multi") do
      user = User.new
      user.define_singleton_method(:save) { raise ActiveRecord::RecordNotUnique }
      original = User.method(:new)
      User.define_singleton_method(:new) do |attributes = nil, **|
        user.assign_attributes(attributes || {})
        user
      end

      post accounts_path, params: {
        user: {
          email_address: "race@example.com",
          password: "a proper password",
          password_confirmation: "a proper password"
        }
      }

      assert_response :unprocessable_content
      assert_select "[role=alert]", /Email address has already been taken/
    ensure
      User.define_singleton_method(:new, original) if original
    end
  end

  test "multi mode keeps accounts isolated" do
    with_account_mode("multi") do
      sign_out
      post session_path, params: { email_address: users(:one).email_address, password: "password" }
      assert_redirected_to root_path

      get transactions_path

      assert_response :success
      assert_no_match(/Owner trade/, response.body)
    end
  end

  test "multi mode scopes instrument positions to the signed-in account" do
    with_account_mode("multi") do
      sign_out
      post session_path, params: { email_address: users(:one).email_address, password: "password" }
      assert_redirected_to root_path

      get instrument_path(instruments(:voo_arcx))

      assert_response :success
      assert_includes response.body, "Other owner trade"
      refute_includes response.body, "Long-term allocation"
    end
  end

  test "switching back to single mode invalidates another account session" do
    with_account_mode("multi") do
      sign_out
      post session_path, params: { email_address: users(:one).email_address, password: "password" }
      assert_redirected_to root_path

      Rails.application.config.x.caramelo.account_mode = "single"
      get root_path

      assert_redirected_to new_session_path
      assert users(:one).trades.exists?(instrument: instruments(:voo_arcx))
    end
  end

  test "switching from public single mode to password protection requires setup" do
    previous_mode = Rails.application.config.x.caramelo.account_mode
    previous_authentication = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.account_mode = "single"
    Rails.application.config.x.caramelo.authentication_mode = "public"
    User.owner.update!(password_configured_at: nil)

    get root_path
    assert_response :success

    Rails.application.config.x.caramelo.authentication_mode = "password"
    get root_path

    assert_redirected_to new_account_setup_path
  ensure
    Rails.application.config.x.caramelo.account_mode = previous_mode
    Rails.application.config.x.caramelo.authentication_mode = previous_authentication
  end

  test "multi mode rejects sessions without a configured password" do
    with_account_mode("multi") do
      user = users(:one)
      user.update!(password_configured_at: nil)
      sign_in_as(user)

      get root_path

      assert_redirected_to new_session_path
    end
  end

  test "multi mode redirects to first-run setup until any account is configured" do
    with_account_mode("multi") do
      User.update_all(password_configured_at: nil)

      get new_account_path

      assert_redirected_to new_account_setup_path
    end
  end

  test "rate limits repeated account registration attempts" do
    with_account_mode("multi") do
      Rails.cache.clear

      10.times do
        post accounts_path, params: { user: { email_address: "", password: "", password_confirmation: "" } }
      end
      post accounts_path, params: { user: { email_address: "", password: "", password_confirmation: "" } }

      assert_redirected_to new_account_path
      assert_equal I18n.t("alerts.Try again later"), flash[:alert]
    end
  end

  private

  def with_account_mode(mode)
    previous = Rails.application.config.x.caramelo.account_mode
    Rails.application.config.x.caramelo.account_mode = mode
    yield
  ensure
    Rails.application.config.x.caramelo.account_mode = previous
  end
end
