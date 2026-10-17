require "test_helper"

class AccountSetupsControllerTest < ActionDispatch::IntegrationTest
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
