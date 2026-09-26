require "test_helper"

class ScanCorporateActionImportsJobTest < ActiveJob::TestCase
  test "delegates a bounded scan to the idempotent import service" do
    result = Object.new
    received = nil
    original = CorporateActionImports::Scan.method(:call)
    CorporateActionImports::Scan.define_singleton_method(:call) do |**arguments|
      received = arguments
      result
    end

    returned = ScanCorporateActionImportsJob.perform_now(
      user_id: users(:owner).id, from: "2026-08-01", to: "2026-08-31",
      source: "yahoo_finance", instrument_id: instruments(:petr4_bvmf).id
    )

    assert_same result, returned
    assert_equal users(:owner), received.fetch(:user)
    assert_equal instruments(:petr4_bvmf), received.fetch(:instrument)
    assert received.fetch(:strict)
    assert_equal Date.new(2026, 8, 1), received.fetch(:from)
    assert_equal Date.new(2026, 8, 31), received.fetch(:to)
  ensure
    CorporateActionImports::Scan.define_singleton_method(:call, original)
  end
end
