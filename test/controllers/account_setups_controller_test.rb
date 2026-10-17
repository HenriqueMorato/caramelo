require "test_helper"

class AccountSetupsControllerTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  teardown do
    users(:owner).update_columns(
      password_digest: BCrypt::Password.create("password"),
      password_configured_at: Time.current
    )
    users(:one).update_columns(password_configured_at: Time.current)
    Rails.cache.clear
  end

  test "redirects protected pages to setup when the owner has no configured password" do
    User.owner.update!(password_configured_at: nil)

    get root_path

    assert_redirected_to new_account_setup_path
  end

  test "renders a post form for first-run setup" do
    User.owner.update!(password_configured_at: nil)

    get new_account_setup_path

    assert_response :success
    assert_select "form[action='#{account_setup_path}'][method='post']"
  end

  test "sets the owner's password and starts a session" do
    User.owner.update!(password_configured_at: nil)

    post account_setup_path, params: {
      user: { password: "a proper password", password_confirmation: "a proper password" }
    }

    assert_redirected_to root_path
    assert_predicate User.owner.reload, :password_configured?
    assert cookies[:session_id]
    assert User.owner.authenticate("a proper password")
  end

  test "keeps setup open when passwords do not match" do
    User.owner.update!(password_configured_at: nil)

    post account_setup_path, params: {
      user: { password: "first password", password_confirmation: "different password" }
    }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /doesn't match/
    assert_not User.owner.reload.password_configured?
  end

  test "does not accept a blank first-run password" do
    User.owner.update!(password_configured_at: nil)

    post account_setup_path, params: {
      user: { password: "", password_confirmation: "" }
    }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Password can't be blank/
    assert_not User.owner.reload.password_configured?
  end

  test "configured owners cannot reopen setup" do
    get new_account_setup_path

    assert_redirected_to new_session_path
  end

  test "configured owners cannot claim setup with a second password" do
    post account_setup_path, params: {
      user: { password: "another password", password_confirmation: "another password" }
    }

    assert_redirected_to new_session_path
    assert User.owner.reload.authenticate("password")
  end

  test "does not overwrite a password configured while setup was opening" do
    owner = users(:owner)
    owner.update!(password_configured_at: nil)
    original = User.method(:owner_or_initialize)
    calls = 0
    User.define_singleton_method(:owner_or_initialize) do
      calls += 1
      owner.update_column(:password_configured_at, Time.current) if calls == 2
      owner
    end

    post account_setup_path, params: {
      user: { password: "another password", password_confirmation: "another password" }
    }

    assert_redirected_to new_session_path
    assert owner.reload.authenticate("password")
  ensure
    User.define_singleton_method(:owner_or_initialize, original) if original
  end

  test "creates the configured owner when the database has not been seeded" do
    email = "first-owner@example.com"
    previous = Rails.application.config.x.caramelo.owner_email
    Rails.application.config.x.caramelo.owner_email = email

    assert_difference("User.count") do
      post account_setup_path, params: {
        user: { password: "a proper password", password_confirmation: "a proper password" }
      }
    end

    assert_redirected_to root_path
    assert User.find_by!(email_address: email).authenticate("a proper password")
  ensure
    User.find_by(email_address: email)&.destroy!
    Rails.application.config.x.caramelo.owner_email = previous
  end

  test "public single-account mode skips password setup" do
    previous = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.authentication_mode = "public"
    User.owner.update!(password_configured_at: nil)

    get new_account_setup_path

    assert_redirected_to root_path
  ensure
    Rails.application.config.x.caramelo.authentication_mode = previous
  end

  test "public single-account setup redirects without double rendering" do
    previous = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.authentication_mode = "public"

    get new_account_setup_path

    assert_redirected_to root_path
  ensure
    Rails.application.config.x.caramelo.authentication_mode = previous
  end

  test "multi-account setup cannot claim the owner after another account is configured" do
    previous = Rails.application.config.x.caramelo.account_mode
    Rails.application.config.x.caramelo.account_mode = "multi"
    User.owner.update!(password_configured_at: nil)
    users(:one).update!(password_configured_at: Time.current)

    post account_setup_path, params: {
      user: { password: "attacker password", password_confirmation: "attacker password" }
    }

    assert_redirected_to new_session_path
    assert_not User.owner.reload.authenticate("attacker password")
  ensure
    Rails.application.config.x.caramelo.account_mode = previous
  end

  test "rate limits repeated first-run setup attempts" do
    User.owner.update!(password_configured_at: nil)
    Rails.cache.clear

    10.times do
      post account_setup_path, params: { user: { password: "", password_confirmation: "" } }
    end
    post account_setup_path, params: { user: { password: "", password_confirmation: "" } }

    assert_redirected_to new_account_setup_path
    assert_equal I18n.t("alerts.Try again later"), flash[:alert]
  end
end
