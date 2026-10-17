require "test_helper"

class Caramelo::PasswordProvisionerTest < ActiveSupport::TestCase
  test "sets the first password for the configured owner" do
    owner = users(:owner)
    owner.update!(password_configured_at: nil)

    result = Caramelo::PasswordProvisioner.setup_owner(
      password: "Strongpass1!", password_confirmation: "Strongpass1!"
    )

    assert_equal owner, result
    assert_predicate owner.reload, :password_configured?
    assert owner.authenticate("Strongpass1!")
  end

  test "creates and configures a missing owner" do
    email = "terminal-owner@example.com"
    previous_email = Rails.application.config.x.caramelo.owner_email
    Rails.application.config.x.caramelo.owner_email = email

    with_stubbed_method(User, :exists?, ->(*) { false }) do
      assert_difference("User.count") do
        result = Caramelo::PasswordProvisioner.setup_owner(
          password: "Strongpass1!", password_confirmation: "Strongpass1!"
        )
        assert_equal email, result.email_address
      end
    end
  ensure
    User.find_by(email_address: email)&.destroy!
    Rails.application.config.x.caramelo.owner_email = previous_email
  end

  test "refuses to create a new owner when another account already exists" do
    previous_email = Rails.application.config.x.caramelo.owner_email
    Rails.application.config.x.caramelo.owner_email = "renamed-owner@example.com"

    error = assert_raises(Caramelo::PasswordProvisioner::NotReady) do
      Caramelo::PasswordProvisioner.setup_owner(
        password: "Strongpass1!", password_confirmation: "Strongpass1!"
      )
    end

    assert_equal "Configured owner email does not match an existing account. Restore CARAMELO_OWNER_EMAIL before setup.",
      error.message
  ensure
    Rails.application.config.x.caramelo.owner_email = previous_email
  end

  test "reports a concurrent owner creation" do
    owner = User.new(email_address: "concurrent-owner@example.com")
    owner.define_singleton_method(:save!) { raise ActiveRecord::RecordNotUnique }

    original_lookup = User.method(:owner_or_initialize)
    User.define_singleton_method(:owner_or_initialize) { owner }

    begin
      with_stubbed_method(User, :exists?, ->(*) { false }) do
        error = assert_raises(Caramelo::PasswordProvisioner::NotReady) do
          Caramelo::PasswordProvisioner.setup_owner(
            password: "Strongpass1!", password_confirmation: "Strongpass1!"
          )
        end

        assert_equal "The configured owner was created by another process. Try again.", error.message
      end
    ensure
      User.define_singleton_method(:owner_or_initialize, original_lookup)
    end
  end

  test "does not overwrite a configured owner" do
    error = assert_raises(Caramelo::PasswordProvisioner::NotReady) do
      Caramelo::PasswordProvisioner.setup_owner(
        password: "Anotherpass1!", password_confirmation: "Anotherpass1!"
      )
    end

    assert_equal "The configured owner already has a password.", error.message
    assert users(:owner).authenticate("password")
  end

  test "changes a password only after checking the current password" do
    user = users(:owner)
    session = user.sessions.create!
    original_digest = user.password_digest
    disconnected = []

    with_stubbed_method(ApplicationCable::Connection, :disconnect_user, ->(account) { disconnected << account }) do
      Caramelo::PasswordProvisioner.change(
        user:, current_password: "password", password: "Changedpass1!", password_confirmation: "Changedpass1!"
      )
    end

    assert_not_equal original_digest, user.reload.password_digest
    assert user.authenticate("Changedpass1!")
    assert_not Session.exists?(session.id)
    assert_equal [ user ], disconnected
  end

  test "rejects a change when the current password is wrong" do
    user = users(:owner)
    original_digest = user.password_digest

    assert_raises(Caramelo::PasswordProvisioner::InvalidCurrentPassword) do
      Caramelo::PasswordProvisioner.change(
        user:, current_password: "wrong", password: "Changedpass1!", password_confirmation: "Changedpass1!"
      )
    end

    assert_equal original_digest, user.reload.password_digest
  end

  test "requires first-run setup before changing an unconfigured password" do
    user = users(:owner)
    user.update!(password_configured_at: nil)

    error = assert_raises(Caramelo::PasswordProvisioner::NotReady) do
      Caramelo::PasswordProvisioner.change(
        user:, current_password: "password", password: "Changedpass1!", password_confirmation: "Changedpass1!"
      )
    end

    assert_equal "This account does not have a configured password.", error.message
  end

  test "resets a password explicitly and revokes existing sessions" do
    user = users(:owner)
    session = user.sessions.create!
    disconnected = []

    with_stubbed_method(ApplicationCable::Connection, :disconnect_user, ->(account) { disconnected << account }) do
      Caramelo::PasswordProvisioner.reset(
        user:, password: "Recoveredpass1!", password_confirmation: "Recoveredpass1!"
      )
    end

    assert user.reload.authenticate("Recoveredpass1!")
    assert_not Session.exists?(session.id)
    assert_equal [ user ], disconnected
  end

  test "keeps a password change successful when cable disconnection fails" do
    user = users(:owner)

    with_stubbed_method(ApplicationCable::Connection, :disconnect_user, ->(*) { raise "cable unavailable" }) do
      Caramelo::PasswordProvisioner.change(
        user:, current_password: "password", password: "Changedpass1!", password_confirmation: "Changedpass1!"
      )
    end

    assert user.reload.authenticate("Changedpass1!")
  end

  test "does not use recovery reset for an unconfigured account" do
    user = users(:owner)
    user.update!(password_configured_at: nil)

    assert_raises(Caramelo::PasswordProvisioner::NotReady) do
      Caramelo::PasswordProvisioner.reset(
        user:, password: "Recoveredpass1!", password_confirmation: "Recoveredpass1!"
      )
    end
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original) if original
  end
end
