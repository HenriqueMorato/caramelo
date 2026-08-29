require "test_helper"

class HistoricalExchangeRateTest < ActiveSupport::TestCase
  setup do
    @attributes = {
      base_currency: "USD", quote_currency: "BRL", rate_date: Date.new(2026, 8, 28),
      rate: BigDecimal("5.432109876543"), provider: "Yahoo_Finance_FX",
      observed_at: Time.utc(2026, 8, 28, 21), fetched_at: Time.current
    }
  end

  test "stores a precise normalized rate" do
    record = HistoricalExchangeRate.create!(@attributes)

    assert_equal BigDecimal("5.432109876543"), record.reload.rate
    assert_equal "USD", record.base_currency
    assert_equal "BRL", record.quote_currency
    assert_equal "yahoo_finance_fx", record.provider
  end

  test "requires distinct currencies" do
    record = HistoricalExchangeRate.new(@attributes.merge(quote_currency: "USD"))

    assert_not record.valid?
    assert_includes record.errors[:quote_currency], "is invalid"
  end

  test "enforces one rate per pair date and provider" do
    HistoricalExchangeRate.create!(@attributes)
    duplicate = HistoricalExchangeRate.new(@attributes)

    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "rejects non-positive rates at the model and database" do
    record = HistoricalExchangeRate.new(@attributes.merge(rate: 0))

    assert_not record.valid?
    assert_raises(ActiveRecord::StatementInvalid) do
      HistoricalExchangeRate.insert_all!([ @attributes.merge(rate: 0, created_at: Time.current, updated_at: Time.current) ])
    end
  end
end
