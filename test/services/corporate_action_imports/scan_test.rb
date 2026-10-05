require "test_helper"

class CorporateActionImports::ScanTest < ActiveSupport::TestCase
  setup do
    CorporateActionImport.delete_all
    @instrument = instruments(:petr4_bvmf)
    Trade.create!(
      user: users(:owner), instrument: @instrument, institution: institutions(:owner_xp),
      side: :buy, traded_on: Date.new(2026, 8, 1), quantity: 1, unit_price: 10,
      fees_cents: 0, currency: "BRL"
    )
    @candidate = CorporateActionImports::Candidate.new(
      kind: "split", source_reference: "PETR4.SA:split:123",
      event_on: Date.new(2026, 8, 20), amount_per_share: nil,
      ratio_numerator: 2, ratio_denominator: 1, currency: "BRL",
      provider_symbol: "PETR4.SA", provider_exchange: "BVMF",
      raw_payload: { "splitRatio" => "2:1" }, warnings: []
    )
  end

  test "scans only the requested historical range and never confirms a candidate" do
    provider = FakeProvider.new(@candidate)

    result = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider:
    )

    assert_equal 1, result.created_count
    assert_equal 1, result.reviewable_count
    import = result.imports.sole
    assert_equal "pending", import.status
    assert_nil import.corporate_action
    assert_equal [ [ @instrument, Date.new(2026, 8, 1), Date.new(2026, 8, 31) ] ], provider.requests
  end

  test "flags a provider event that may duplicate a manually entered event" do
    users(:owner).corporate_actions.create!(
      instrument: @instrument, kind: :stock_split, status: :confirmed,
      effective_on: @candidate.event_on, ratio_numerator: 2, ratio_denominator: 1,
      source: "manual"
    )

    import = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(@candidate)
    ).imports.sole

    assert_equal "pending", import.status
    assert_includes import.warning_list, "possible_duplicate"
  end

  test "matches a provider cash event against a manual payment date" do
    users(:owner).corporate_actions.create!(
      instrument: @instrument, kind: :dividend, status: :confirmed,
      paid_on: @candidate.event_on + 5.days, gross_amount_cents: 100,
      withholding_tax_cents: 0, net_amount_cents: 100, currency: "BRL", source: "manual"
    )
    candidate = @candidate.with(
      kind: "dividend", amount_per_share: BigDecimal("0.25"), ratio_numerator: nil,
      ratio_denominator: nil, event_on: @candidate.event_on + 5.days
    )

    import = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(candidate)
    ).imports.sole

    assert_includes import.warning_list, "possible_duplicate"
  end

  test "skips provider events from dates when the owner had no position" do
    before_first_trade = @candidate.with(
      source_reference: "PETR4.SA:split:before-first-trade", event_on: Date.new(2026, 7, 31)
    )
    provider = ListProvider.new([ before_first_trade, @candidate ])

    result = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 7, 1), to: Date.new(2026, 8, 31), provider:
    )

    assert_equal [ @candidate.source_reference ], result.imports.map(&:source_reference)
    assert_equal Date.new(2026, 8, 1), provider.requests.sole[1]
    assert_equal 1, result.created_count
  end

  test "keeps a candidate when position replay is invalid" do
    scan = CorporateActionImports::Scan.new(
      user: users(:owner), from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31),
      source: "yahoo_finance", instrument: @instrument, provider: EmptyProvider.new, strict: false
    )
    error = Position::InvalidLongOnlyData.new(Trade.new(id: 1))
    original = Position::Calculator.method(:quantity_timeline)
    Position::Calculator.define_singleton_method(:quantity_timeline) { |**| raise error }

    assert scan.send(:candidate_has_position?, @instrument, @candidate)
  ensure
    Position::Calculator.define_singleton_method(:quantity_timeline, original) if original
  end

  test "collects provider errors unless strict mode is requested" do
    provider = ErrorProvider.new
    result = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider:
    )
    assert_equal 1, result.error_count
    assert_empty result.imports

    assert_raises(StandardError) do
      CorporateActionImports::Scan.call(
        user: users(:owner), instrument: @instrument,
        from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider:, strict: true
      )
    end
  end

  test "scans all traded instruments when no instrument is selected" do
    provider = EmptyProvider.new

    result = CorporateActionImports::Scan.call(
      user: users(:owner), from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider:
    )

    assert_empty result.imports
    assert_equal 2, provider.requests.size
    assert_equal [ "PETR4", "VOO" ], provider.requests.map(&:ticker).sort
  end

  test "rejects an instrument that is not traded by the owner" do
    untraded = Instrument.create!(ticker: "UNTR", exchange: "BVMF", name: "Untraded", currency: "BRL")

    assert_raises(ArgumentError) do
      CorporateActionImports::Scan.call(
        user: users(:owner), instrument: untraded,
        from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: EmptyProvider.new
      )
    end
  end

  test "reports blank provider references and invalid ranges" do
    blank_reference = @candidate.with(source_reference: nil)
    result = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(blank_reference)
    )
    assert_equal 1, result.error_count

    assert_raises(ArgumentError) do
      CorporateActionImports::Scan.call(
        user: users(:owner), instrument: @instrument, source: "manual",
        from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: EmptyProvider.new
      )
    end
    assert_raises(ArgumentError) do
      CorporateActionImports::Scan.call(
        user: users(:owner), instrument: @instrument,
        from: Date.current + 1.day, to: Date.current + 2.days, provider: EmptyProvider.new
      )
    end
  end

  test "stops before persisting when a scan generation is superseded" do
    calls = 0
    fence = lambda do |&block|
      calls += 1
      calls == 1 ? block.call : false
    end

    assert_raises(CorporateActionImports::Scan::Superseded) do
      CorporateActionImports::Scan.call(
        user: users(:owner), instrument: @instrument,
        from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(@candidate),
        fence:
      )
    end

    assert_equal 2, calls
    assert_empty CorporateActionImport.where(source_reference: @candidate.source_reference)
  end

  test "raises before fetching when a scan generation is already superseded" do
    assert_raises(CorporateActionImports::Scan::Superseded) do
      CorporateActionImports::Scan.call(
        user: users(:owner), instrument: @instrument,
        from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: EmptyProvider.new,
        fence: ->(&) { false }
      )
    end
  end

  test "persists candidates while the scan generation remains current" do
    result = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(@candidate),
      fence: ->(&block) { block.call }
    )

    assert_equal 1, result.created_count
    assert_equal [ @candidate.source_reference ], result.imports.map(&:source_reference)
  end

  test "rerunning a scan updates unresolved payloads without creating duplicates" do
    provider = FakeProvider.new(@candidate)
    first = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider:
    )
    changed = @candidate.with(raw_payload: { "splitRatio" => "3:1" }, ratio_numerator: 3)
    provider.candidate = changed

    second = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider:
    )

    assert_equal 1, first.created_count
    assert_equal 0, second.created_count
    assert_equal 1, CorporateActionImport.count
    assert_equal 3, CorporateActionImport.first.ratio_numerator
    assert_equal "pending", CorporateActionImport.first.status
  end

  test "marks a confirmed payload correction as a conflict" do
    import = CorporateActionImport.create!(
      build_import.attributes.merge(
        status: :confirmed,
        corporate_action: create_action(source: "yahoo_finance", source_reference: "PETR4.SA:split:123")
      )
    )
    provider = FakeProvider.new(@candidate.with(ratio_numerator: 3, raw_payload: { "splitRatio" => "3:1" }))

    result = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider:
    )

    assert_equal "conflict", result.imports.sole.status
    assert_equal import.corporate_action_id, result.imports.sole.corporate_action_id
  end

  test "keeps an unchanged confirmed payload idempotent" do
    first = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(@candidate)
    )
    import = first.imports.sole
    CorporateActionImports::Confirmation.call(import:)

    second = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(@candidate)
    )

    assert_equal "confirmed", second.imports.sole.status
    assert_equal 1, CorporateAction.where(source_reference: import.source_reference).count
  end

  test "does not erase reviewed accounting fields when a confirmed scan is repeated" do
    candidate = @candidate.with(kind: "dividend", ratio_numerator: nil, ratio_denominator: nil, amount_per_share: BigDecimal("0.25"))
    first = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(candidate)
    )
    import = first.imports.sole
    CorporateActionImports::Review.call(import:, attributes: {
      kind: "dividend", paid_on: "2026-08-25", gross_amount: "100", withholding_tax: "15"
    })

    action_result = CorporateActionImports::Confirmation.call(import:)
    assert_predicate action_result, :confirmed?

    second = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(candidate)
    )

    assert_equal "confirmed", second.imports.sole.status
    assert_equal 10_000, second.imports.sole.gross_amount_cents
    assert_equal Date.new(2026, 8, 25), second.imports.sole.paid_on
  end

  test "preserves reviewed accounting fields when a pending scan is repeated" do
    candidate = @candidate.with(
      kind: "dividend", ratio_numerator: nil, ratio_denominator: nil,
      amount_per_share: BigDecimal("0.25")
    )
    first = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(candidate)
    )
    import = first.imports.sole
    CorporateActionImports::Review.call(import:, attributes: {
      kind: "dividend", paid_on: "2026-08-25", gross_amount: "100", withholding_tax: ""
    })

    second = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(candidate)
    )

    assert_equal "pending", second.imports.sole.status
    assert_equal 10_000, second.imports.sole.gross_amount_cents
    assert_equal 0, second.imports.sole.withholding_tax_cents
    assert_equal Date.new(2026, 8, 25), second.imports.sole.paid_on
    assert_equal Time.current.to_date, second.imports.sole.reviewed_at.to_date
  end

  test "requires institution resolution when an instrument has multiple institutions" do
    Trade.create!(
      user: users(:owner), instrument: @instrument, institution: institutions(:owner_inactive),
      side: :buy, traded_on: Date.new(2026, 8, 2), quantity: 1, unit_price: 11,
      fees_cents: 0, currency: "BRL"
    )

    result = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(@candidate)
    )
    import = result.imports.sole

    assert_equal "ambiguous", import.status
    refute_predicate import, :ready_for_confirmation?

    reviewed = CorporateActionImports::Review.call(import:, attributes: { institution_id: institutions(:owner_xp).id })

    assert_predicate reviewed, :success?
    assert_equal "pending", import.reload.status
    assert_predicate import, :ready_for_confirmation?
  end

  test "applies a reviewed provider correction to the existing authoritative action" do
    first = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(@candidate)
    )
    import = first.imports.sole
    CorporateActionImports::Confirmation.call(import:)

    changed_provider = FakeProvider.new(@candidate.with(
      ratio_numerator: 3, raw_payload: { "splitRatio" => "3:1" }
    ))
    conflict = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: changed_provider
    ).imports.sole
    assert_equal "conflict", conflict.status

    CorporateActionImports::Review.call(import: conflict, attributes: {
      kind: "split", effective_on: "2026-08-20", ratio_numerator: 3, ratio_denominator: 1,
      accept_provider_update: true
    })
    result = CorporateActionImports::Confirmation.call(import: conflict)

    assert_predicate result, :confirmed?
    assert_equal 3, conflict.reload.corporate_action.ratio_numerator
    assert_equal 1, CorporateAction.where(source_reference: conflict.source_reference).count
  end

  test "does not create another provider action after a manual duplicate is confirmed" do
    first = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(@candidate)
    )
    import = first.imports.sole
    CorporateActionImports::Confirmation.call(import:)

    users(:owner).corporate_actions.create!(
      instrument: @instrument, kind: :stock_split, status: :confirmed,
      effective_on: @candidate.event_on, ratio_numerator: 2, ratio_denominator: 1,
      source: "manual"
    )

    second = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(@candidate)
    )

    assert_equal 0, second.created_count
    assert_equal 1, CorporateAction.where(source: "yahoo_finance", source_reference: import.source_reference).count
    assert_equal 2, CorporateAction.where(instrument: @instrument).count
    assert_includes second.imports.sole.warning_list, "possible_duplicate"
  end

  test "coalesces a concurrent create after the unique constraint wins" do
    existing = build_import
    existing.save!
    scan = CorporateActionImports::Scan.new(
      user: users(:owner), from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31),
      source: "yahoo_finance", instrument: @instrument, provider: EmptyProvider.new, strict: false
    )
    calls = 0
    original_persist_import = scan.method(:persist_import)
    scan.define_singleton_method(:persist_import, lambda { |import, _instrument, _candidate, was_new:|
      calls += 1
      raise ActiveRecord::RecordNotUnique if calls == 1

      [ import, was_new ]
    })
    result = scan.send(:persist_new_import, @instrument, @candidate, @candidate.source_reference)

    assert_equal [ existing, false ], result
  ensure
    scan.define_singleton_method(:persist_import, original_persist_import) if scan && original_persist_import
  end

  test "canonicalizes nested payloads and exposes the default provider" do
    scan = CorporateActionImports::Scan.new(
      user: users(:owner), from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31),
      source: "yahoo_finance", instrument: @instrument, provider: EmptyProvider.new, strict: false
    )
    assert_equal '{"a":[{"a":2,"z":1},"x"],"b":null}', scan.send(
      :canonical_json, { "b" => nil, "a" => [ { "z" => 1, "a" => 2 }, "x" ] }
    )
    assert_instance_of CorporateActionImports::Providers::YahooFinance, scan.send(:default_provider)
  end

  test "leaves institution unresolved when no trade institution exists" do
    instrument = Instrument.create!(ticker: "NOI", exchange: "BVMF", name: "No institution", currency: "BRL")
    Trade.create!(
      user: users(:owner), instrument:, institution: nil, side: :buy, traded_on: Date.new(2026, 8, 1),
      quantity: 1, unit_price: 10, fees_cents: 0, currency: "BRL"
    )
    candidate = @candidate.with(source_reference: "NOI:split:1")

    import = CorporateActionImports::Scan.call(
      user: users(:owner), instrument:, from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31),
      provider: FakeProvider.new(candidate)
    ).imports.sole

    assert_equal "pending", import.status
    assert_nil import.institution
    assert_empty import.warning_list
  end

  test "preserves a missing candidate date in normalized data" do
    candidate = @candidate.with(source_reference: "missing-date", event_on: nil)
    import = CorporateActionImports::Scan.call(
      user: users(:owner), instrument: @instrument,
      from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31), provider: FakeProvider.new(candidate)
    ).imports.sole

    assert_nil import.normalized_candidate.fetch("event_on")
  end

  class FakeProvider
    attr_accessor :candidate
    attr_reader :requests

    def initialize(candidate)
      @candidate = candidate
      @requests = []
    end

    def fetch(instrument:, from:, to:)
      requests << [ instrument, from, to ]
      [ candidate ]
    end
  end

  class ListProvider
    attr_reader :requests

    def initialize(candidates)
      @candidates = candidates
      @requests = []
    end

    def fetch(instrument:, from:, to:)
      requests << [ instrument, from, to ]
      @candidates
    end
  end

  class EmptyProvider
    attr_reader :requests

    def initialize
      @requests = []
    end

    def fetch(instrument:, from:, to:)
      requests << instrument
      []
    end
  end

  class ErrorProvider
    def fetch(**)
      raise StandardError, "provider down"
    end
  end

  def create_action(source:, source_reference:)
    CorporateAction.create!(
      user: users(:owner), instrument: @instrument, kind: :stock_split,
      status: :confirmed, effective_on: Date.new(2026, 8, 20), ratio_numerator: 2,
      ratio_denominator: 1, source:, source_reference:
    )
  end

  def build_import
    CorporateActionImport.new(
      user: users(:owner), instrument: @instrument,
      source: "yahoo_finance", source_reference: "PETR4.SA:split:123",
      status: :pending, kind: "split", event_on: Date.new(2026, 8, 20),
      ratio_numerator: 2, ratio_denominator: 1, currency: "BRL",
      normalized_data: {}, raw_payload: {}, warnings: []
    )
  end
end
