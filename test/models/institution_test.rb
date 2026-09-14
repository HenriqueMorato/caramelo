require "test_helper"

class InstitutionTest < ActiveSupport::TestCase
  test "belongs to an owner and defaults to active" do
    institution = Institution.new(user: users(:owner), name: "BTG Pactual")

    assert_equal users(:owner), institution.user
    assert_predicate institution, :active?
    assert_predicate institution, :valid?
  end

  test "normalizes and requires a name" do
    institution = Institution.new(user: users(:owner), name: "  BTG   Pactual  ")

    assert_equal "BTG Pactual", institution.name

    institution.name = "  "

    assert_predicate institution, :invalid?
    assert_includes institution.errors[:name], "can't be blank"
  end

  test "prevents case-insensitive duplicate names for one owner" do
    duplicate = Institution.new(user: users(:owner), name: "xp investimentos")

    assert_predicate duplicate, :invalid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "enforces case-insensitive uniqueness in the database" do
    now = Time.current
    attributes = {
      user_id: users(:owner).id,
      name: "Case Broker",
      slug: "case-broker-test",
      active: true,
      created_at: now,
      updated_at: now
    }

    Institution.insert_all!([ attributes ])

    assert_raises ActiveRecord::RecordNotUnique do
      Institution.insert_all!([ attributes.merge(name: "case broker", slug: "case-broker-duplicate") ])
    end
  end

  test "allows the same name for different owners" do
    institution = Institution.new(user: users(:one), name: "XP Investimentos")

    assert_predicate institution, :valid?
  end

  test "generates a readable collision-safe slug" do
    first = Institution.create!(user: users(:owner), name: "Friendly Bank")
    second = Institution.create!(user: users(:one), name: "Friendly Bank")

    assert_equal "friendly-bank", first.slug
    assert_equal "friendly-bank-#{users(:one).id}", second.slug
  end

  test "keeps its slug when its name changes" do
    institution = institutions(:owner_xp)

    assert_no_changes -> { institution.reload.slug } do
      institution.update!(name: "XP")
    end
  end

  test "filters active institutions alphabetically" do
    assert_equal [ institutions(:owner_xp) ], users(:owner).institutions.active.alphabetical.to_a
  end

  test "deletes an unused institution" do
    institution = Institution.create!(user: users(:owner), name: "Unused broker")

    assert_difference("Institution.count", -1) { institution.destroy }
    assert_predicate institution, :destroyed?
  end
end
