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

  test "reopens the review when its authoritative action is deleted" do
    import = build_import
    CorporateActionImports::Confirmation.call(import:)

    import.corporate_action.destroy!

    assert_equal "pending", import.reload.status
    assert_nil import.corporate_action_id
    assert_nil import.reviewed_at
  end

  test "recovers an orphaned confirmed import during confirmation" do
    import = build_import
    CorporateActionImports::Confirmation.call(import:)
    import.update_columns(corporate_action_id: nil)

    result = CorporateActionImports::Confirmation.call(import:)

    assert_predicate result, :duplicate?
    assert_equal "confirmed", import.reload.status
    assert_not_nil import.corporate_action_id
  end

  test "blocks confirmation until an ambiguous institution is resolved" do
    import = build_import(status: :ambiguous, institution: nil)

    result = CorporateActionImports::Confirmation.call(import:)

    assert_predicate result, :ambiguous?
    assert_predicate result, :skipped?
    assert_match(/institution must be selected/, result.error)
  end

  test "skips ignored and conflicted imports" do
    ignored = build_import(source_reference: "ignored-confirmation", status: :ignored)
    conflicted = build_import(source_reference: "conflicted-confirmation", status: :conflict, failure_message: "changed")

    assert_predicate CorporateActionImports::Confirmation.call(import: ignored), :skipped?
    conflict_result = CorporateActionImports::Confirmation.call(import: conflicted)
    assert_predicate conflict_result, :skipped?
    assert_equal :conflict, conflict_result.status
  end

  test "updates a linked pending action instead of creating a duplicate" do
    action = CorporateAction.create!(
      user: users(:owner), instrument: instruments(:petr4_bvmf), kind: :stock_split,
      status: :pending, effective_on: Date.new(2026, 8, 20), ratio_numerator: 2,
      ratio_denominator: 1, source: "yahoo_finance", source_reference: "linked-pending"
    )
    import = build_import(source_reference: "linked-pending", corporate_action: action)

    result = CorporateActionImports::Confirmation.call(import:)

    assert_predicate result, :confirmed?
    assert_equal action.id, result.corporate_action.id
    assert_equal "confirmed", action.reload.status
  end

  test "uses the instrument currency and handles blank tax cents" do
    import = build_import(
      source_reference: "cash-fallback", kind: "dividend", currency: nil,
      event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 20),
      ratio_numerator: nil, ratio_denominator: nil
    )
    result = CorporateActionImports::Confirmation.call(import:, attributes: {
      paid_on: "2026-08-25", gross_amount_cents: "10000", withholding_tax: ""
    })

    assert_predicate result, :confirmed?
    assert_equal "BRL", result.corporate_action.currency
    assert_equal 10_000, result.corporate_action.net_amount_cents
  end

  test "accepts explicit quantity fields and rejects blank ratios" do
    import = build_import(source_reference: "quantity-attributes")
    result = CorporateActionImports::Confirmation.call(import:, attributes: {
      effective_on: "2026-08-21", ratio_numerator: "3", ratio_denominator: "2"
    })
    assert_predicate result, :confirmed?
    assert_equal 3, result.corporate_action.ratio_numerator

    blank = build_import(source_reference: "quantity-blank")
    failed = CorporateActionImports::Confirmation.call(import: blank, attributes: {
      effective_on: "2026-08-21", ratio_numerator: "", ratio_denominator: "2"
    })
    assert_predicate failed, :failed?
  end

  test "fails cleanly for non-finite confirmation amounts" do
    import = build_import(
      source_reference: "cash-nan", kind: "dividend", event_on: Date.new(2026, 8, 20),
      ex_date: Date.new(2026, 8, 20), ratio_numerator: nil, ratio_denominator: nil
    )
    result = CorporateActionImports::Confirmation.call(import:, attributes: {
      paid_on: "2026-08-25", gross_amount: "Infinity"
    })

    assert_predicate result, :failed?
    assert_match(/amount is invalid/, result.error)
    assert_equal "failed", import.reload.status
  end

  test "marks a unique conflict as duplicate when the action already exists" do
    import = build_import(source_reference: "forced-duplicate")
    existing = CorporateAction.create!(
      user: import.user, instrument: import.instrument, kind: :stock_split,
      status: :confirmed, effective_on: import.event_on, ratio_numerator: 2,
      ratio_denominator: 1, source: import.source, source_reference: import.source_reference
    )
    replacement = CorporateAction.new
    replacement.define_singleton_method(:save!) { raise ActiveRecord::RecordNotUnique, "duplicate" }
    original_new = CorporateAction.method(:new)
    CorporateAction.define_singleton_method(:new) { replacement }
    result = CorporateActionImports::Confirmation.call(import:)
    assert_predicate result, :duplicate?
    assert_equal existing, result.corporate_action
  ensure
    CorporateAction.define_singleton_method(:new, original_new) if original_new
  end

  test "keeps a unique conflict failed when no action can be found" do
    import = build_import(source_reference: "forced-failure")
    replacement = CorporateAction.new
    replacement.define_singleton_method(:save!) { raise ActiveRecord::RecordNotUnique, "duplicate" }
    original_new = CorporateAction.method(:new)
    CorporateAction.define_singleton_method(:new) { replacement }
    result = CorporateActionImports::Confirmation.call(import:)
    assert_predicate result, :failed?
    assert_equal "failed", import.reload.status
  ensure
    CorporateAction.define_singleton_method(:new, original_new) if original_new
  end

  test "reports missing currency when the instrument is also absent" do
    import = build_import(source_reference: "missing-currency", instrument: nil, currency: nil,
      kind: "dividend", event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 20),
      ratio_numerator: nil, ratio_denominator: nil)
    result = CorporateActionImports::Confirmation.call(import:, attributes: {
      paid_on: "2026-08-25", gross_amount: "10"
    })

    assert_predicate result, :failed?
    assert_match(/currency is required/, result.error)
  end

  test "ignores a failure when recording its error is unavailable" do
    import = build_import(source_reference: "unrecordable-failure")
    import.define_singleton_method(:update_columns) { |**| raise ActiveRecord::StatementInvalid, "locked" }
    replacement = CorporateAction.new
    replacement.define_singleton_method(:save!) { raise ActiveRecord::RecordNotUnique, "duplicate" }
    original_new = CorporateAction.method(:new)
    CorporateAction.define_singleton_method(:new) { replacement }
    result = CorporateActionImports::Confirmation.call(import:)

    assert_predicate result, :failed?
  ensure
    CorporateAction.define_singleton_method(:new, original_new) if original_new
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
