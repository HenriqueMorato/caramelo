require "test_helper"

class OwnerSeedTest < ActiveSupport::TestCase
  test "creates the configured owner idempotently" do
    owner_email = Rails.application.config.x.local_folio.owner_email
    User.where(email_address: owner_email).destroy_all

    assert_difference -> { User.where(email_address: owner_email).count }, 1 do
      load Rails.root.join("db/seeds.rb")
    end

    assert_no_difference -> { User.where(email_address: owner_email).count } do
      load Rails.root.join("db/seeds.rb")
    end

    assert_predicate User.owner.password_digest, :present?
  end
end
