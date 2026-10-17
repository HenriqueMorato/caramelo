require "test_helper"

class Caramelo::AccountProvisionerTest < ActiveSupport::TestCase
  setup do
    @previous_mode = Rails.application.config.x.caramelo.account_mode
    Rails.application.config.x.caramelo.account_mode = "multi"
  end

  teardown do
    Rails.application.config.x.caramelo.account_mode = @previous_mode
  end

  test "creates a configured account in multi-account mode" do
    assert_difference("User.count") do
      @user = Caramelo::AccountProvisioner.call(
        email_address: "new-person@example.com",
        password: "Strongpass1!",
        password_confirmation: "Strongpass1!"
      )
    end

    assert_equal "new-person@example.com", @user.email_address
    assert_predicate @user, :password_configured?
    assert @user.authenticate("Strongpass1!")
  end

  test "requires multi-account mode" do
    Rails.application.config.x.caramelo.account_mode = "single"

    error = assert_raises(Caramelo::AccountProvisioner::NotReady) do
      provision_account
    end

    assert_equal "Set CARAMELO_ACCOUNT_MODE=multi before creating another account.", error.message
  end

  test "requires the configured owner to have a password first" do
    User.owner.update!(password_configured_at: nil)

    error = assert_raises(Caramelo::AccountProvisioner::NotReady) do
      provision_account
    end

    assert_equal "Set the configured owner's password with bin/caramelo-password setup first.", error.message
  end

  test "applies the password policy before creating an account" do
    assert_no_difference("User.count") do
      assert_raises(ActiveRecord::RecordInvalid) { provision_account(password: "weak") }
    end
  end

  test "rejects duplicate email addresses" do
    assert_no_difference("User.count") do
      assert_raises(ActiveRecord::RecordInvalid) do
        provision_account(email_address: users(:owner).email_address)
      end
    end
  end

  private

    def provision_account(email_address: "new-person@example.com", password: "Strongpass1!")
      Caramelo::AccountProvisioner.call(
        email_address:, password:, password_confirmation: password
      )
    end
end
