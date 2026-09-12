require "test_helper"

class OwnerSeedTest < ActiveSupport::TestCase
  test "keeps an existing legacy owner instead of creating a second owner" do
    assert_no_difference -> { User.count } do
      load Rails.root.join("db/seeds.rb")
    end

    assert_equal Caramelo::Environment::LEGACY_OWNER_EMAIL, User.owner.email_address
  end

  test "creates the configured owner idempotently" do
    owner_email = Rails.application.config.x.caramelo.owner_email
    owner_emails = [ owner_email, Caramelo::Environment::LEGACY_OWNER_EMAIL ]
    Trade.where(user: User.where(email_address: owner_emails)).delete_all
    User.where(email_address: owner_emails).destroy_all

    assert_difference -> { User.where(email_address: owner_email).count }, 1 do
      load Rails.root.join("db/seeds.rb")
    end

    assert_no_difference -> { User.where(email_address: owner_email).count } do
      load Rails.root.join("db/seeds.rb")
    end

    assert_predicate User.owner.password_digest, :present?
  end
end
