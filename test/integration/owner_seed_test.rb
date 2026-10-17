require "test_helper"

class OwnerSeedTest < ActiveSupport::TestCase
  test "creates the configured owner idempotently" do
    owner_email = Rails.application.config.x.caramelo.owner_email
    Trade.where(user: User.where(email_address: owner_email)).delete_all
    User.where(email_address: owner_email).destroy_all

    with_stubbed_method(User, :owner_configuration_conflict?, -> { false }) do
      assert_difference -> { User.where(email_address: owner_email).count }, 1 do
        load Rails.root.join("db/seeds.rb")
      end

      assert_no_difference -> { User.where(email_address: owner_email).count } do
        load Rails.root.join("db/seeds.rb")
      end
    end

    assert_predicate User.owner.password_digest, :present?
  end

  test "refuses to seed a replacement owner when the configured email changes" do
    configured_email = Rails.application.config.x.caramelo.owner_email
    Rails.application.config.x.caramelo.owner_email = "renamed-owner@example.com"

    error = assert_raises(ArgumentError) { load Rails.root.join("db/seeds.rb") }

    assert_equal "CARAMELO_OWNER_EMAIL does not match an existing account", error.message
  ensure
    Rails.application.config.x.caramelo.owner_email = configured_email
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
