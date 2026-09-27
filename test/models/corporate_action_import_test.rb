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

  test "provides enum and dynamic currency predicates" do
    import = build_import

    assert_predicate import, :split?
    assert_predicate import, :currency_brl?
    refute_predicate import, :currency_usd?
    assert_predicate instruments(:voo_arcx), :currency_usd?
  end

  test "uses a friendly slug and derives review defaults" do
    import = build_import(
      instrument: instruments(:voo_arcx), currency: "USD", kind: "dividend",
      event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 20),
      ratio_numerator: nil, ratio_denominator: nil, amount_per_share: "0.25"
    )
    import.save!

    assert_match(/\Aimp-[a-z0-9-]+\z/, import.slug)
    assert_equal import, CorporateActionImport.friendly.find(import.slug)
    assert_equal Date.new(2026, 8, 20), import.suggested_payment_date
    assert_equal 63, import.estimated_gross_amount_cents
  end

  test "keeps provisional review defaults safe when source values are incomplete" do
    dividend = build_import(
      instrument: instruments(:voo_arcx), currency: nil, kind: "dividend",
      event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 19),
      paid_on: Date.new(2026, 8, 21), ratio_numerator: nil, ratio_denominator: nil,
      amount_per_share: "0.25"
    )
    assert_equal Date.new(2026, 8, 21), dividend.suggested_payment_date
    assert_equal "USD", dividend.review_currency
    assert_equal 63, dividend.estimated_gross_amount_cents
    assert_nil build_import(instrument: nil, currency: nil).review_currency
    assert_nil build_import(instrument: nil, currency: nil).estimated_gross_amount_cents

    assert_nil build_import(gross_amount_cents: 10).estimated_gross_amount_cents
    assert_nil build_import(kind: "split").estimated_gross_amount_cents
    assert_nil build_import(amount_per_share: nil).estimated_gross_amount_cents
    assert_nil build_import(
      instrument: instruments(:voo_arcx), currency: "USD", kind: "dividend",
      event_on: Date.new(2020, 1, 1), amount_per_share: "0.25",
      ratio_numerator: nil, ratio_denominator: nil
    ).estimated_gross_amount_cents
    assert_nil build_import(
      instrument: instruments(:voo_arcx), currency: "USD", kind: "dividend",
      event_on: Date.new(2026, 8, 20), amount_per_share: "not-a-number",
      ratio_numerator: nil, ratio_denominator: nil
    ).estimated_gross_amount_cents
    assert_nil build_import(
      instrument: instruments(:voo_arcx), currency: "USD", kind: "dividend",
      event_on: Date.new(2026, 8, 20), amount_per_share: "NaN",
      ratio_numerator: nil, ratio_denominator: nil
    ).estimated_gross_amount_cents
  end

  test "exposes the supported kind list and quantity predicates" do
    assert_equal %w[dividend jcp split reverse_split share_bonus], CorporateActionImport.kinds_for_select

    reverse = build_import(kind: "reverse_split", ratio_numerator: 1, ratio_denominator: 2)
    assert_predicate reverse, :quantity_action?
    assert_predicate reverse, :reverse_split?
    refute_predicate reverse, :cash_action?
  end

  test "requires complete fields only for a pending import" do
    complete = build_import
    assert_predicate complete, :ready_for_confirmation?
    refute_predicate build_import(status: :confirmed), :ready_for_confirmation?
    refute_predicate build_import(instrument: nil), :ready_for_confirmation?
    refute_predicate build_import(status: :ambiguous, institution: nil), :ready_for_confirmation?
    refute_predicate build_import(ratio_numerator: nil), :ready_for_confirmation?
  end

  test "marks an import reviewed and tolerates malformed stored JSON" do
    import = build_import
    import.save!
    import.mark_reviewed!(status: :pending)

    assert_not_nil import.reload.reviewed_at
    import.update_columns(normalized_data: "not-json", warnings: "{}")
    assert_equal({}, import.normalized_candidate)
    assert_equal([], import.warning_list)

    import.update_columns(normalized_data: "", warnings: "")
    assert_equal({}, import.normalized_candidate)
    assert_equal([], import.warning_list)
  end

  test "allows a BRL JCP and handles an import without an owner" do
    jcp = build_import(kind: "jcp", currency: nil)
    assert_predicate jcp, :valid?

    ownerless = build_import(user: nil)
    ownerless.valid?
    assert_empty ownerless.errors.details[:institution]
  end

  test "rejects associations belonging to another owner or instrument" do
    action = CorporateAction.new(
      user: users(:one), instrument: instruments(:voo_arcx), kind: :stock_split,
      status: :confirmed, effective_on: Date.new(2026, 8, 20), ratio_numerator: 2,
      ratio_denominator: 1, source: "manual", source_reference: "wrong-import-action"
    )
    import = build_import(corporate_action: action)

    assert_not import.valid?
    codes = import.errors.details[:corporate_action].map { |error| error[:error] }
    assert_includes codes, :wrong_owner
    assert_includes codes, :instrument_mismatch
  end

  test "rejects JCP for a non-BRL instrument" do
    import = build_import(instrument: instruments(:voo_arcx), currency: "USD", kind: "jcp")
    mismatched_currency = build_import(currency: "USD", kind: "jcp")

    assert_not import.valid?
    assert_includes import.errors[:kind], "must use a BRL instrument"
    assert_not mismatched_currency.valid?
    assert_not build_import(instrument: nil, currency: "BRL", kind: "jcp").valid?
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
