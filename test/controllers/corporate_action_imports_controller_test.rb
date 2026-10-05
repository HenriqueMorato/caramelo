require "test_helper"

class CorporateActionImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    CorporateActionImport.delete_all
    CorporateAction.delete_all
    Rails.cache.clear
    clear_enqueued_jobs
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

  test "queues an explicit bounded scan and redirects with its status state" do
    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance" }
    }

    assert_response :redirect
    assert_equal "Scan queued. This page will refresh when it finishes.", flash[:notice]
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == ScanCorporateActionImportsJob }
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    scope = CorporateActionImports::ScanStatus.scope(
      user: users(:owner), from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31),
      source: "yahoo_finance", instrument_id: nil
    )
    assert_equal "queued", RefreshStatus::State.read(scope).status
    assert_equal RefreshStatus::State.read(scope).run_id, query.fetch("scan_run_id")
    assert_equal "2026-08-01", query.fetch("from")
    assert_equal "2026-08-31", query.fetch("to")
  end

  test "renders aligned scan controls with the shared field treatment" do
    get corporate_action_imports_url

    assert_response :success
    assert_select "form[action='#{corporate_action_imports_path}'] select.ui-field", count: 2
    assert_select "form[action='#{corporate_action_imports_path}'] button.ui-button-primary.min-h-\\[3\\.125rem\\]", count: 1
  end

  test "keeps the scan filters selected while the queued scan is active" do
    post corporate_action_imports_url, params: {
      scan: {
        from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance",
        instrument_id: instruments(:voo_arcx).id
      }
    }
    query = Rack::Utils.parse_query(URI.parse(response.location).query)

    get response.location

    assert_response :success
    assert_select "#corporate-action-scan-status", text: /Provider scan queued/
    assert_select "select[name='scan[instrument_id]'] option[selected][value='#{instruments(:voo_arcx).id}']"
    assert_select "turbo-cable-stream-source", minimum: 2
    assert_equal "2026-08-01", query.fetch("from")
  end

  test "does not enqueue a duplicate scan while the same request is active" do
    params = {
      scan: {
        from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance",
        instrument_id: instruments(:voo_arcx).id
      }
    }

    post corporate_action_imports_url, params: params
    post corporate_action_imports_url, params: params

    assert_equal 1, enqueued_jobs.count { |job| job[:job] == ScanCorporateActionImportsJob }
    assert_equal "A scan with these settings is already running.", flash[:notice]
  end

  test "reports when a scan cannot be enqueued" do
    original = ScanCorporateActionImportsJob.method(:perform_later)
    ScanCorporateActionImportsJob.define_singleton_method(:perform_later) do |**|
      raise ActiveJob::EnqueueError, "queue unavailable"
    end

    post corporate_action_imports_url, params: {
      scan: {
        from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance",
        instrument_id: instruments(:voo_arcx).id
      }
    }

    assert_equal corporate_action_imports_path, URI.parse(response.location).path
    assert URI.parse(response.location).query.include?("scan_run_id=")
    assert_equal "The scan could not be started. Try again.", flash[:alert]

    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-02", to: "2026-08-31", source: "yahoo_finance" }
    }
    assert_equal "The scan could not be started. Try again.", flash[:alert]
  ensure
    ScanCorporateActionImportsJob.define_singleton_method(:perform_later, original)
  end

  test "does not enqueue a duplicate owner-wide scan" do
    params = { scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance" } }

    post corporate_action_imports_url, params: params
    post corporate_action_imports_url, params: params

    assert_equal 1, enqueued_jobs.count { |job| job[:job] == ScanCorporateActionImportsJob }
  end

  test "shows a failed scan with a retry link" do
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scope = CorporateActionImports::ScanStatus.scope(
      user: users(:owner), from:, to:, source: "yahoo_finance", instrument_id: nil
    )
    state = CorporateActionImports::ScanStatus.enqueue(scope:)
    CorporateActionImports::ScanStatus.fail(scope:, run_id: state.run_id, error: RuntimeError.new("provider down"))

    get corporate_action_imports_url(
      from: from, to:, source: "yahoo_finance", scan_run_id: state.run_id
    )

    assert_select "#corporate-action-scan-status[aria-live=polite]", text: /provider scan failed/i
    assert_select "#corporate-action-scan-status a", text: "Retry scan", count: 1
  end

  test "shows an interrupted scan with a retry link" do
    from = Date.new(2026, 8, 1)
    to = Date.new(2026, 8, 31)
    scope = CorporateActionImports::ScanStatus.scope(
      user: users(:owner), from:, to:, source: "yahoo_finance", instrument_id: nil
    )
    travel_to 11.minutes.ago do
      CorporateActionImports::ScanStatus.enqueue(scope:)
    end

    get corporate_action_imports_url(
      from: from, to:, source: "yahoo_finance", scan_run_id: RefreshStatus::State.read(scope).run_id
    )

    assert_select "#corporate-action-scan-status", text: /stopped before completion/i
    assert_select "#corporate-action-scan-status a", text: "Retry scan", count: 1
  end

  test "redirects invalid scan dates with an alert" do
    post corporate_action_imports_url, params: {
      scan: { from: "not-a-date", to: "2026-08-31", source: "yahoo_finance" }
    }

    assert_redirected_to corporate_action_imports_url
    assert_equal "Enter a valid date range.", flash[:alert]
  end

  test "rejects a scan range in the future or reverse order" do
    travel_to Date.new(2026, 9, 27) do
      post corporate_action_imports_url, params: {
        scan: { from: "2026-09-28", to: "2026-09-29", source: "yahoo_finance" }
      }
      assert_equal "Enter a valid date range.", flash[:alert]

      post corporate_action_imports_url, params: {
        scan: { from: "2026-08-31", to: "2026-08-01", source: "yahoo_finance" }
      }
      assert_equal "Enter a valid date range.", flash[:alert]
    end
  end

  test "does not subscribe to a status run that belongs to another request" do
    get corporate_action_imports_url(
      from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance", scan_run_id: "unknown"
    )

    assert_response :success
    assert_select "#corporate-action-scan-status", text: ""
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
    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance", instrument_id: instruments(:voo_arcx).id }
    }
    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance", instrument_id: "999999" }
    }
    post corporate_action_imports_url, params: {
      scan: { from: "2026-08-01", to: "2026-08-31", source: "yahoo_finance", instrument_id: "not-an-id" }
    }

    job = enqueued_jobs.find { |entry| entry[:job] == ScanCorporateActionImportsJob }
    assert_equal instruments(:voo_arcx).id, job[:args].last.fetch("instrument_id")
    assert_equal "Select an instrument traded by this owner.", flash[:alert]
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
