require "test_helper"

class CorporateActionImports::ScanTest < ActiveSupport::TestCase
  setup do
    CorporateActionImport.delete_all
    @instrument = instruments(:petr4_bvmf)
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
