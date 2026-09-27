require "test_helper"

class CorporateActionImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    CorporateActionImport.delete_all
    CorporateAction.delete_all
  end

  test "lists old candidates before applying them and distinguishes confirmable rows" do
    split = build_import(source_reference: "split-1", kind: "split", event_on: Date.new(2026, 8, 20), ratio_numerator: 2, ratio_denominator: 1)
    dividend = build_import(
      source_reference: "dividend-1", kind: "dividend", event_on: Date.new(2026, 8, 21),
      ex_date: Date.new(2026, 8, 21), ratio_numerator: nil, ratio_denominator: nil,
      amount_per_share: "0.25", warnings: [ "payment_date_required" ]
    )

    get corporate_action_imports_url

    assert_response :success
    assert_select "h1", "Review imported events"
    assert_select "tr##{dom_id(split)} input[type=checkbox]:not([disabled])", count: 1
    assert_select "tr##{dom_id(dividend)} input[type=checkbox][disabled]", count: 1
    assert_select "tr##{dom_id(dividend)}", text: /Payment date required/
    assert_empty CorporateAction.all
  end

  test "confirms selected historical quantity events without applying unselected rows" do
    split = build_import(source_reference: "split-2", kind: "split", event_on: Date.new(2026, 8, 20), ratio_numerator: 2, ratio_denominator: 1)
    dividend = build_import(
      source_reference: "dividend-2", kind: "dividend", event_on: Date.new(2026, 8, 21),
      ex_date: Date.new(2026, 8, 21), ratio_numerator: nil, ratio_denominator: nil,
      amount_per_share: "0.25"
    )

    post bulk_confirm_corporate_action_imports_url, params: { import_ids: [ split.id ] }

    assert_redirected_to corporate_action_imports_url
    assert_equal "confirmed", split.reload.status
    assert_equal "pending", dividend.reload.status
    assert_equal 1, CorporateAction.count
  end

  test "bulk confirmation keeps successful rows when another selected row fails" do
    split = build_import(source_reference: "split-partial", kind: "split", event_on: Date.new(2026, 8, 20), ratio_numerator: 2, ratio_denominator: 1)
    dividend = build_import(
      source_reference: "dividend-partial", kind: "dividend", event_on: Date.new(2026, 8, 21),
      ex_date: Date.new(2026, 8, 21), ratio_numerator: nil, ratio_denominator: nil,
      amount_per_share: "0.25"
    )

    post bulk_confirm_corporate_action_imports_url, params: { import_ids: [ split.id, dividend.id ] }

    assert_equal "confirmed", split.reload.status
    assert_equal "failed", dividend.reload.status
    assert_equal 1, CorporateAction.count
  end

  test "saves payment fields and reclassifies a Brazilian dividend as JCP" do
    import = build_import(
      source_reference: "dividend-3", kind: "dividend", event_on: Date.new(2026, 8, 21),
      ex_date: Date.new(2026, 8, 21), ratio_numerator: nil, ratio_denominator: nil,
      amount_per_share: "0.25"
    )

    patch corporate_action_import_url(import), params: {
      corporate_action_import: {
        kind: "jcp", paid_on: "2026-08-25", ex_date: "2026-08-21",
        gross_amount: "100", withholding_tax: "15"
      }
    }
    assert_redirected_to corporate_action_imports_url

    post confirm_corporate_action_import_url(import)

    assert_redirected_to corporate_action_imports_url
    action = CorporateAction.find_by!(source_reference: import.source_reference)
    assert_equal "jcp", action.kind
    assert_equal 8_500, action.net_amount_cents
  end

  test "defaults blank withholding tax to zero" do
    import = build_import(
      source_reference: "dividend-no-tax", kind: "dividend", event_on: Date.new(2026, 8, 21),
      ex_date: Date.new(2026, 8, 21), ratio_numerator: nil, ratio_denominator: nil,
      amount_per_share: "0.25"
    )

    patch corporate_action_import_url(import), params: {
      corporate_action_import: {
        kind: "dividend", paid_on: "2026-08-25", ex_date: "2026-08-21",
        gross_amount: "100", withholding_tax: ""
      }
    }

    assert_redirected_to corporate_action_imports_url
    assert_equal 0, import.reload.withholding_tax_cents
  end

  test "does not offer JCP for a USD instrument" do
    import = build_import(
      instrument: instruments(:voo_arcx), currency: "USD", kind: "dividend",
      source_reference: "usd-dividend", event_on: Date.new(2026, 8, 21),
      ex_date: Date.new(2026, 8, 21), ratio_numerator: nil, ratio_denominator: nil
    )

    get edit_corporate_action_import_url(import)

    assert_response :success
    assert_select "select[name='corporate_action_import[kind]'] option[value='jcp']", count: 0
  end

  test "starts an explicit bounded scan and reports provider results" do
    result = CorporateActionImports::Scan::Result.new(
      Date.new(2026, 8, 1), Date.new(2026, 8, 31), "yahoo_finance", [], [], 0
    )
    original = CorporateActionImports::Scan.method(:call)
    received = nil
    CorporateActionImports::Scan.define_singleton_method(:call) do |**arguments|
      received = arguments
      result
    end

    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance" }
    }

    assert_redirected_to corporate_action_imports_url
    assert_equal Date.new(2026, 8, 1), received.fetch(:from)
    assert_equal Date.new(2026, 8, 31), received.fetch(:to)
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end

  private

  def build_import(overrides = {})
    CorporateActionImport.create!({
      user: users(:owner), instrument: instruments(:petr4_bvmf),
      source: "yahoo_finance", source_reference: "candidate-#{SecureRandom.hex(4)}",
      status: :pending, kind: "split", event_on: Date.new(2026, 8, 20),
      ratio_numerator: 2, ratio_denominator: 1, currency: "BRL",
      normalized_data: {}, raw_payload: {}, warnings: []
    }.merge(overrides))
  end
end
