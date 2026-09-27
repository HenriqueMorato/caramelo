require "test_helper"

class CorporateActionImports::EditPresenterTest < ActiveSupport::TestCase
  setup do
    CorporateActionImport.delete_all
  end

  test "prepares ordinary quantity event state" do
    import = build_import
    presenter = CorporateActionImports::EditPresenter.new(
      import:, institutions: [ institutions(:owner_xp) ]
    )

    assert_equal "split", presenter.current_kind
    assert_equal import.event_on, presenter.current_event_on
    assert_equal %w[split reverse_split share_bonus], presenter.kind_options
    assert_equal "split", presenter.review_kind
    assert_equal import.event_on, presenter.review_event_on
    assert_equal import.ratio_numerator, presenter.review_ratio_numerator
    assert_equal import.ratio_denominator, presenter.review_ratio_denominator
    assert_equal import.ex_date, presenter.review_ex_date
    refute_predicate presenter, :conflict?
    refute_predicate presenter, :cash_action?
    refute_predicate presenter, :institution_select?
    assert_predicate presenter, :hidden_institution?
    assert_equal import.institution, presenter.institution
    assert_equal import.institution_id, presenter.institution_id
    assert_nil presenter.gross_amount_value
    assert_nil presenter.withholding_tax_value
  end

  test "prepares a cash event with estimated accounting values" do
    import = build_import(
      instrument: instruments(:voo_arcx), institution: nil, currency: "USD", kind: "dividend",
      event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 20),
      ratio_numerator: nil, ratio_denominator: nil, amount_per_share: "0.25",
      withholding_tax_cents: 10
    )
    presenter = CorporateActionImports::EditPresenter.new(import:, institutions: [])

    assert_predicate presenter, :cash_action?
    assert_predicate presenter, :payment_date_suggested?
    assert_equal %w[dividend], presenter.kind_options
    assert_equal Date.new(2026, 8, 20), presenter.suggested_payment_date
    assert_equal "0.63", presenter.gross_amount_value
    assert_equal BigDecimal("0.1"), presenter.withholding_tax_value
    assert_equal "USD", presenter.review_currency
    assert_equal 100, presenter.currency_subunit
    refute_predicate presenter, :institution_select?
    refute_predicate presenter, :hidden_institution?
  end

  test "uses provider values when a reviewed event conflicts" do
    import = build_import(
      status: :conflict, failure_message: "provider changed",
      normalized_data: {
        "kind" => "dividend", "event_on" => "2026-08-22", "amount_per_share" => "0.25",
        "ratio_numerator" => nil, "ratio_denominator" => nil
      }, raw_payload: { "amount" => "0.25" }
    )
    presenter = CorporateActionImports::EditPresenter.new(import:, institutions: [])

    assert_predicate presenter, :conflict?
    assert_equal "dividend", presenter.review_kind
    assert_equal "2026-08-22", presenter.review_event_on
    assert_equal import.ratio_numerator, presenter.review_ratio_numerator
    assert_equal import.ratio_denominator, presenter.review_ratio_denominator
    assert_equal "2026-08-22", presenter.review_ex_date
    assert_equal "0.25", presenter.provider_amount_per_share
    assert_equal({ "amount" => "0.25" }, presenter.provider_payload)
    assert_equal %w[dividend jcp], presenter.kind_options
    assert_predicate presenter, :cash_action?
  end

  test "falls back to reviewed values for an incomplete provider candidate" do
    import = build_import(
      instrument: nil, institution: nil, currency: nil, status: :conflict,
      normalized_data: {}, raw_payload: {}, gross_amount_cents: 100,
      withholding_tax_cents: nil
    )
    presenter = CorporateActionImports::EditPresenter.new(
      import:, institutions: [ institutions(:owner_xp), institutions(:owner_inactive) ]
    )

    assert_nil presenter.provider_kind
    assert_nil presenter.provider_event_on
    assert_nil presenter.provider_ratio
    assert_nil presenter.provider_amount_per_share
    assert_equal "split", presenter.review_kind
    assert_equal import.event_on, presenter.review_event_on
    assert_equal import.ratio_numerator, presenter.review_ratio_numerator
    assert_equal import.ratio_denominator, presenter.review_ratio_denominator
    assert_equal import.ex_date, presenter.review_ex_date
    assert_equal %w[split reverse_split share_bonus], presenter.kind_options
    assert_equal "1.0", presenter.gross_amount_value
    assert_nil presenter.withholding_tax_value
    assert_equal 100, presenter.currency_subunit
    assert_predicate presenter, :institution_select?
    refute_predicate presenter, :hidden_institution?
  end

  test "offers all kinds when the reviewed event has no kind" do
    presenter = CorporateActionImports::EditPresenter.new(
      import: build_import(kind: nil), institutions: []
    )

    assert_equal CorporateActionImport.kinds.keys, presenter.kind_options
    assert_nil presenter.review_kind
    refute_predicate presenter, :cash_action?
  end

  private

  def build_import(overrides = {})
    CorporateActionImport.create!({
      user: users(:owner), instrument: instruments(:petr4_bvmf), institution: institutions(:owner_xp),
      source: "yahoo_finance", source_reference: "presenter-#{SecureRandom.hex(4)}",
      status: :pending, kind: "split", event_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 20),
      ratio_numerator: 2, ratio_denominator: 1, currency: "BRL", normalized_data: {}, raw_payload: {}, warnings: []
    }.merge(overrides))
  end
end
