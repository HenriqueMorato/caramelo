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

  test "prefills a provisional payment date and gross amount estimate" do
    import = build_import(
      instrument: instruments(:voo_arcx), currency: "USD", kind: "dividend",
      source_reference: "usd-dividend-estimate", event_on: Date.new(2026, 8, 20),
      ex_date: Date.new(2026, 8, 20), ratio_numerator: nil, ratio_denominator: nil,
      amount_per_share: "0.25"
    )

    get edit_corporate_action_import_url(import)

    assert_response :success
    assert_select "input[name='corporate_action_import[paid_on]'][value='2026-08-20']"
    assert_select "input[name='corporate_action_import[gross_amount]'][value='0.63']"
    assert_select "#corporate-action-import-payment-date-help", text: /not a reliable payment date/
    assert_select "#corporate-action-import-gross-amount-help", text: /quantity held on the event date/
  end

  test "shows provider corrections before a conflicted import can be reviewed" do
    import = build_import(
      source_reference: "conflict-details", status: :conflict,
      normalized_data: {
        "kind" => "split", "event_on" => "2026-08-22", "ratio_numerator" => 3,
        "ratio_denominator" => 1, "amount_per_share" => nil
      }, raw_payload: { "splitRatio" => "3:1" }
    )

    get edit_corporate_action_import_url(import)

    assert_response :success
    assert_select "aside[aria-labelledby='corporate-action-import-conflict-heading']"
    assert_select "input[name='corporate_action_import[accept_provider_update]'][required]", count: 1
    assert_select "input[name='corporate_action_import[effective_on]'][value='2026-08-22']"
    assert_select "input[name='corporate_action_import[ratio_numerator]'][value='3']"
    assert_select "pre", text: /splitRatio/
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

  test "renders aligned scan controls with the shared field treatment" do
    get corporate_action_imports_url

    assert_response :success
    assert_select "form[action='#{corporate_action_imports_path}'] select.ui-field", count: 2
    assert_select "form[action='#{corporate_action_imports_path}'] button.ui-button-primary.min-h-11", count: 1
  end

  test "reports provider scan errors in the flash" do
    result = CorporateActionImports::Scan::Result.new(
      Date.new(2026, 8, 1), Date.new(2026, 8, 31), "yahoo_finance", [],
      [ { instrument: instruments(:petr4_bvmf), error: StandardError.new("provider down") } ], 0
    )
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) { |**| result }

    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance" }
    }

    assert_redirected_to corporate_action_imports_url
    assert_match(/Skipped 1 instrument scan/, flash[:notice])
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end

  test "redirects invalid scan dates with an alert" do
    post corporate_action_imports_url, params: {
      scan: { from: "not-a-date", to: "2026-08-31", source: "yahoo_finance" }
    }

    assert_redirected_to corporate_action_imports_url
    assert_equal "Enter a valid date range.", flash[:alert]
  end

  test "renders the edit form when review validation fails" do
    import = build_import(source_reference: "review-failure", instrument: instruments(:voo_arcx), currency: "USD")
    patch corporate_action_import_url(import), params: {
      corporate_action_import: { kind: "jcp" }
    }

    assert_response :unprocessable_content
    assert_select "div[role=alert]", text: /BRL instrument/
  end

  test "ignores one imported event" do
    import = build_import(source_reference: "ignore-controller")

    post ignore_corporate_action_import_url(import)

    assert_redirected_to corporate_action_imports_url
    assert_equal "ignored", import.reload.status
    assert_match(/ignored/i, flash[:notice])
  end

  test "bulk ignores selected imported events" do
    first = build_import(source_reference: "bulk-ignore-one")
    second = build_import(source_reference: "bulk-ignore-two")

    post bulk_ignore_corporate_action_imports_url, params: { import_ids: [ first.id, second.id ] }

    assert_redirected_to corporate_action_imports_url
    assert_equal [ "ignored", "ignored" ], [ first.reload.status, second.reload.status ]
    assert_match(/Ignored 2/, flash[:notice])
  end

  test "supports all and specific status filters" do
    pending = build_import(source_reference: "status-pending")
    failed = build_import(source_reference: "status-failed", status: :failed, failure_message: "bad payload")

    get corporate_action_imports_url(status: "all")
    assert_response :success
    assert_select "tr##{dom_id(pending)}", count: 1
    assert_select "tr##{dom_id(failed)}", count: 1

    get corporate_action_imports_url(status: "failed")
    assert_response :success
    assert_select "tr##{dom_id(failed)}", count: 1
    assert_select "tr##{dom_id(pending)}", count: 0
  end

  test "passes a valid scan instrument and rejects an unknown target" do
    result = CorporateActionImports::Scan::Result.new(
      Date.new(2026, 8, 1), Date.new(2026, 8, 31), "yahoo_finance", [], [], 0
    )
    original = CorporateActionImports::Scan.method(:call)
    received = []
    CorporateActionImports::Scan.define_singleton_method(:call) do |**arguments|
      received << arguments
      result
    end

    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance", instrument_id: instruments(:voo_arcx).id }
    }
    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance", instrument_id: "999999" }
    }
    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance", instrument_id: "not-an-id" }
    }

    assert_equal instruments(:voo_arcx), received.first.fetch(:instrument)
    assert_equal 1, received.size
    assert_equal "Select an instrument traded by this owner.", flash[:alert]
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end

  test "normalizes invalid dates in the history filter" do
    get corporate_action_imports_url(from: "not-a-date", to: "2026-08-31")

    assert_response :success
    assert_select "h1", "Review imported events"
    controller = CorporateActionImportsController.new
    assert_equal Date.current, controller.send(:parse_date, Date.current)
  end

  test "shows duplicate, ambiguous, and failed confirmation feedback" do
    split = build_import(source_reference: "flash-duplicate")
    post confirm_corporate_action_import_url(split)
    post confirm_corporate_action_import_url(split)
    assert_match(/already confirmed/i, flash[:notice])

    ambiguous = build_import(source_reference: "flash-ambiguous", status: :ambiguous, institution: nil)
    post confirm_corporate_action_import_url(ambiguous)
    assert_match(/institution must be selected/i, flash[:alert])

    failed = build_import(
      source_reference: "flash-failed", kind: "dividend", event_on: Date.new(2026, 8, 20),
      ex_date: Date.new(2026, 8, 20), ratio_numerator: nil, ratio_denominator: nil
    )
    post confirm_corporate_action_import_url(failed)
    assert_match(/Paid on|Gross amount/i, flash[:alert])
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
