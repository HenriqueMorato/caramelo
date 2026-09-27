require "test_helper"

class CorporateActionImports::ReviewTest < ActiveSupport::TestCase
  setup do
    CorporateActionImport.delete_all
  end

  test "does not edit a confirmed import" do
    import = build_import
    CorporateActionImports::Confirmation.call(import:)

    result = CorporateActionImports::Review.call(import:, attributes: { kind: "reverse_split" })

    refute_predicate result, :success?
    assert_match(/Confirmed imports cannot be edited/, result.error)
  end

  test "requires an event type" do
    import = build_import(kind: nil)

    result = CorporateActionImports::Review.call(import:)

    refute_predicate result, :success?
    assert_equal "event type is required", result.error
  end

  test "reviews quantity fields and clears cash fields" do
    import = build_import(
      kind: "split", event_on: Date.new(2026, 8, 20), ratio_numerator: 2, ratio_denominator: 1,
      paid_on: Date.new(2026, 8, 25), ex_date: Date.new(2026, 8, 20),
      gross_amount_cents: 100, withholding_tax_cents: 10, net_amount_cents: 90
    )

    result = CorporateActionImports::Review.call(import:, attributes: {
      kind: "stock_split", effective_on: Date.new(2026, 8, 21), ratio_numerator: "3", ratio_denominator: "2"
    })

    assert_predicate result, :success?
    import.reload
    assert_equal "split", import.kind
    assert_equal Date.new(2026, 8, 21), import.event_on
    assert_equal 3, import.ratio_numerator
    assert_equal 2, import.ratio_denominator
    assert_nil import.paid_on
    assert_nil import.gross_amount_cents
    assert_nil import.withholding_tax_cents
    assert_nil import.net_amount_cents
  end

  test "resolves or rejects institution selections" do
    import = build_import(warnings: [ "multiple_institutions" ], institution: nil)

    unresolved = CorporateActionImports::Review.call(import:, attributes: { institution_id: "" })
    assert_predicate unresolved, :success?
    assert_equal "ambiguous", import.reload.status

    invalid = CorporateActionImports::Review.call(
      import:, attributes: { institution_id: institutions(:other_owner).id }
    )
    refute_predicate invalid, :success?
    assert_match(/not available for this owner/, invalid.error)
  end

  test "accepts explicit cents and zero withholding" do
    import = build_import(
      kind: "dividend", event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 20),
      ratio_numerator: nil, ratio_denominator: nil
    )

    result = CorporateActionImports::Review.call(import:, attributes: {
      kind: "dividend", paid_on: Date.new(2026, 8, 25), ex_date: Date.new(2026, 8, 20),
      gross_amount_cents: "10000", withholding_tax_cents: ""
    })

    assert_predicate result, :success?
    assert_equal 10_000, import.reload.gross_amount_cents
    assert_equal 0, import.withholding_tax_cents
    assert_equal 10_000, import.net_amount_cents
  end

  test "keeps existing cash amounts when accounting fields are omitted" do
    import = build_import(
      kind: "dividend", event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 20),
      ratio_numerator: nil, ratio_denominator: nil, paid_on: Date.new(2026, 8, 25),
      gross_amount_cents: 10_000, withholding_tax_cents: 1_000, net_amount_cents: 9_000
    )

    result = CorporateActionImports::Review.call(import:, attributes: { kind: "dividend" })

    assert_predicate result, :success?
    assert_equal 9_000, import.reload.net_amount_cents
  end

  test "rejects malformed dates, numbers, and non-finite amounts" do
    import = build_import(kind: "split")
    invalid_date = CorporateActionImports::Review.call(import:, attributes: { effective_on: "not-a-date" })
    refute_predicate invalid_date, :success?

    invalid_ratio = CorporateActionImports::Review.call(import:, attributes: { effective_on: Date.current, ratio_numerator: "not-a-number" })
    refute_predicate invalid_ratio, :success?

    cash = build_import(
      source_reference: "review-nan", kind: "dividend", event_on: Date.current, ex_date: Date.current,
      ratio_numerator: nil, ratio_denominator: nil
    )
    invalid_amount = CorporateActionImports::Review.call(import: cash, attributes: {
      kind: "dividend", paid_on: Date.current, gross_amount: "NaN"
    })
    refute_predicate invalid_amount, :success?
    assert_match(/amount is invalid/, invalid_amount.error)
  end

  test "handles blank integer and amount inputs" do
    quantity = build_import(source_reference: "review-blank-integer")
    result = CorporateActionImports::Review.call(import: quantity, attributes: {
      kind: "split", effective_on: Date.current, ratio_numerator: "", ratio_denominator: ""
    })
    assert_predicate result, :success?
    refute_predicate quantity.reload, :ready_for_confirmation?

    cash = build_import(
      source_reference: "review-blank-amount", kind: "dividend", event_on: Date.current,
      ex_date: Date.current, ratio_numerator: nil, ratio_denominator: nil,
      gross_amount_cents: 10_000, withholding_tax_cents: 1_000, net_amount_cents: 9_000
    )
    blank_gross = CorporateActionImports::Review.call(import: cash, attributes: {
      kind: "dividend", gross_amount: "", paid_on: Date.current
    })
    assert_predicate blank_gross, :success?
    assert_nil cash.reload.gross_amount_cents

    blank_cents = CorporateActionImports::Review.call(import: cash, attributes: {
      kind: "dividend", paid_on: Date.current, gross_amount_cents: ""
    })
    assert_predicate blank_cents, :success?

    explicit_currency = build_import(
      source_reference: "review-currency-branch", kind: "dividend", event_on: Date.current,
      ex_date: Date.current, ratio_numerator: nil, ratio_denominator: nil
    )
    with_amount = CorporateActionImports::Review.call(import: explicit_currency, attributes: {
      kind: "dividend", paid_on: Date.current, gross_amount: "10"
    })
    assert_predicate with_amount, :success?

    reviewer = CorporateActionImports::Review.new(import: explicit_currency, attributes: { gross_amount: "10" })
    assert_equal 1_000, reviewer.send(:amount_cents, :gross_amount, :gross_amount_cents, nil)

    native_fallback = build_import(
      source_reference: "review-native-currency", currency: nil, kind: "dividend",
      event_on: Date.current, ex_date: Date.current, ratio_numerator: nil, ratio_denominator: nil
    )
    native_result = CorporateActionImports::Review.call(import: native_fallback, attributes: {
      kind: "dividend", paid_on: Date.current, gross_amount: "10"
    })
    assert_predicate native_result, :success?
  end

  test "uses explicit withholding cents and reports missing currency" do
    import = build_import(
      source_reference: "review-explicit-cents", kind: "dividend", event_on: Date.current,
      ex_date: Date.current, ratio_numerator: nil, ratio_denominator: nil
    )
    result = CorporateActionImports::Review.call(import:, attributes: {
      kind: "dividend", paid_on: Date.current, gross_amount_cents: "10000", withholding_tax_cents: "100"
    })
    assert_predicate result, :success?

    missing_currency = build_import(
      source_reference: "review-missing-currency", instrument: nil, currency: nil,
      kind: "dividend", event_on: Date.current, ex_date: Date.current,
      ratio_numerator: nil, ratio_denominator: nil
    )
    failed = CorporateActionImports::Review.call(import: missing_currency, attributes: {
      kind: "dividend", paid_on: Date.current, gross_amount: "10"
    })
    refute_predicate failed, :success?
    assert_match(/currency is required/, failed.error)
  end

  test "reports model validation errors when reclassifying to JCP on a USD instrument" do
    import = build_import(
      source_reference: "review-usd-jcp", instrument: instruments(:voo_arcx), currency: "USD",
      kind: "dividend", event_on: Date.current, ex_date: Date.current,
      ratio_numerator: nil, ratio_denominator: nil
    )
    import.save!

    result = CorporateActionImports::Review.call(import:, attributes: {
      kind: "jcp", paid_on: Date.current, gross_amount: "10"
    })

    refute_predicate result, :success?
    assert_match(/BRL instrument/, result.error)
  end

  private

  def build_import(overrides = {})
    CorporateActionImport.create!({
      user: users(:owner), instrument: instruments(:petr4_bvmf),
      source: "yahoo_finance", source_reference: "review-#{SecureRandom.hex(4)}",
      status: :pending, kind: "split", event_on: Date.new(2026, 8, 20),
      ratio_numerator: 2, ratio_denominator: 1, currency: "BRL",
      normalized_data: {}, raw_payload: {}, warnings: []
    }.merge(overrides))
  end
end
