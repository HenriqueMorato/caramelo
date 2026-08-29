require "test_helper"

class CurrencyCodeTest < ActiveSupport::TestCase
  test "normalizes a supported ISO currency" do
    assert_equal "USD", CurrencyCode.normalize(" usd ")
  end

  test "rejects malformed and unsupported currencies" do
    assert_raises(ArgumentError) { CurrencyCode.normalize("US") }
    assert_raises(ArgumentError) { CurrencyCode.normalize("XXX") }
  end
end
