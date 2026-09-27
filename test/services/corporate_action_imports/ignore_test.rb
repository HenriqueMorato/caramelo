require "test_helper"

class CorporateActionImports::IgnoreTest < ActiveSupport::TestCase
  setup do
    CorporateActionImport.delete_all
    CorporateAction.delete_all
  end

  test "marks a reviewable import ignored" do
    import = CorporateActionImport.create!(
      user: users(:owner), instrument: instruments(:petr4_bvmf), source: "yahoo_finance",
      source_reference: "ignore-me", status: :pending, kind: "split",
      event_on: Date.new(2026, 8, 20), ratio_numerator: 2, ratio_denominator: 1,
      currency: "BRL", normalized_data: {}, raw_payload: {}, warnings: []
    )

    result = CorporateActionImports::Ignore.call(import:)

    assert_equal import, result
    assert_equal "ignored", import.reload.status
    assert_not_nil import.reviewed_at
    assert_nil import.failure_message
  end

  test "does not reopen a confirmed import" do
    import = CorporateActionImport.create!(
      user: users(:owner), instrument: instruments(:petr4_bvmf), source: "yahoo_finance",
      source_reference: "ignore-confirmed", status: :confirmed, kind: "split",
      event_on: Date.new(2026, 8, 20), ratio_numerator: 2, ratio_denominator: 1,
      currency: "BRL", corporate_action: CorporateAction.create!(
        user: users(:owner), instrument: instruments(:petr4_bvmf), kind: :stock_split,
        status: :confirmed, effective_on: Date.new(2026, 8, 20), ratio_numerator: 2,
        ratio_denominator: 1, source: "yahoo_finance", source_reference: "ignore-confirmed"
      ), normalized_data: {}, raw_payload: {}, warnings: []
    )

    CorporateActionImports::Ignore.call(import:)

    assert_equal "confirmed", import.reload.status
    assert_equal "confirmed", import.corporate_action.status
  end
end
