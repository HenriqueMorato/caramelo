require "test_helper"

class CorporateActionImports::ConfirmationTest < ActiveSupport::TestCase
  setup do
    CorporateActionImport.delete_all
    CorporateAction.delete_all
  end

  test "confirms a split through the authoritative corporate action model" do
    import = build_import

    result = CorporateActionImports::Confirmation.call(import:)

    assert_predicate result, :confirmed?
    assert_equal "confirmed", import.reload.status
    assert_equal "stock_split", import.corporate_action.kind
    assert_equal import.source_reference, import.corporate_action.source_reference
  end

  test "requires payment date and credited amount for a dividend" do
    import = build_import(
      kind: "dividend", event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 20),
      ratio_numerator: nil, ratio_denominator: nil, amount_per_share: "0.25"
    )
    result = CorporateActionImports::Confirmation.call(import:)

    assert_predicate result, :failed?
    assert_match(/Paid on|Gross amount/i, result.error)
    assert_equal "failed", import.reload.status
    assert_empty CorporateAction.where(source_reference: import.source_reference)
  end

  test "allows reviewed Brazilian dividends to be reclassified as JCP" do
    import = build_import(
      kind: "dividend", event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 20),
      ratio_numerator: nil, ratio_denominator: nil, amount_per_share: "0.25"
    )
    result = CorporateActionImports::Confirmation.call(
      import:, attributes: {
        kind: "jcp", paid_on: "2026-08-25", gross_amount: "100.00", withholding_tax: "15.00"
      }
    )

    assert_predicate result, :confirmed?
    assert_equal "jcp", result.corporate_action.kind
    assert_equal 10_000, result.corporate_action.gross_amount_cents
    assert_equal 1_500, result.corporate_action.withholding_tax_cents
    assert_equal 8_500, result.corporate_action.net_amount_cents
  end

  test "is idempotent when a confirmation is repeated" do
    import = build_import
    first = CorporateActionImports::Confirmation.call(import:)
    second = CorporateActionImports::Confirmation.call(import:)

    assert_predicate first, :confirmed?
    assert_predicate second, :duplicate?
    assert_equal 1, CorporateAction.where(source_reference: import.source_reference).count
  end

  test "links an unlinked import when the authoritative action already exists" do
    import = build_import
    action = CorporateAction.create!(
      user: import.user, instrument: import.instrument, kind: :stock_split,
      status: :confirmed, effective_on: import.event_on,
      ratio_numerator: import.ratio_numerator, ratio_denominator: import.ratio_denominator,
      source: import.source, source_reference: import.source_reference
    )

    result = CorporateActionImports::Confirmation.call(import:)

    assert_predicate result, :duplicate?
    assert_equal action, import.reload.corporate_action
    assert_equal "confirmed", import.status
  end

  private

  def build_import(overrides = {})
    CorporateActionImport.create!({
      user: users(:owner), instrument: instruments(:petr4_bvmf),
      source: "yahoo_finance", source_reference: "PETR4.SA:split:456",
      status: :pending, kind: "split", event_on: Date.new(2026, 8, 20),
      ratio_numerator: 2, ratio_denominator: 1, currency: "BRL",
      normalized_data: "{}", raw_payload: "{}", warnings: "[]"
    }.merge(overrides))
  end
end
