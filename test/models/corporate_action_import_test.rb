require "test_helper"

class CorporateActionImportTest < ActiveSupport::TestCase
  setup do
    CorporateActionImport.delete_all
  end

  test "belongs to the owner and keeps an optional institution and ledger action" do
    import = build_import(institution: institutions(:owner_xp))

    assert_predicate import, :valid?
    assert_equal users(:owner), import.user
    assert_equal instruments(:petr4_bvmf), import.instrument
    assert_equal institutions(:owner_xp), import.institution
    assert_nil import.corporate_action
  end

  test "enforces one source reference per owner" do
    build_import.save!
    duplicate = build_import

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:source_reference], "has already been taken"
  end

  test "preserves exact candidate decimals and provider payload" do
    import = build_import(amount_per_share: "0.123456789012345678", raw_payload: { "amount" => "0.123456789012345678" })
    import.save!
    import.reload

    assert_equal "0.123456789012345678", import.amount_per_share
    assert_equal({ "amount" => "0.123456789012345678" }, import.raw_payload_hash)
    assert_equal [], import.warning_list
  end

  test "only pending and ambiguous imports can be confirmed" do
    import = build_import(kind: "split", event_on: Date.new(2026, 8, 20), ratio_numerator: 2, ratio_denominator: 1)

    assert_predicate import, :ready_for_confirmation?
    import.status = :confirmed
    assert_not import.valid?
    assert_includes import.errors.full_messages, "Corporate action must exist for a confirmed import"
  end

  test "requires an action for confirmed status and validates association ownership" do
    import = build_import(institution: institutions(:other_owner), status: :pending)

    assert_not import.valid?
    assert_includes import.errors[:institution], "must belong to the import owner"
  end

  private

  def build_import(overrides = {})
    CorporateActionImport.new({
      user: users(:owner), instrument: instruments(:petr4_bvmf),
      source: "yahoo_finance", source_reference: "PETR4.SA:split:123",
      status: :pending, kind: "split", event_on: Date.new(2026, 8, 20),
      ratio_numerator: 2, ratio_denominator: 1, currency: "BRL",
      normalized_data: "{}", raw_payload: "{}", warnings: "[]"
    }.merge(overrides))
  end
end
