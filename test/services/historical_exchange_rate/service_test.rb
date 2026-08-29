require "test_helper"

class HistoricalExchangeRate::ServiceTest < ActiveSupport::TestCase
  setup do
    @date = Date.new(2026, 8, 28)
    @provider = Struct.new(:identifier).new("test_provider")
    @service = HistoricalExchangeRate::Service.new(provider: @provider)
  end

  test "returns same-currency one-to-one without persistence" do
    lookup = @service.read(base_currency: "BRL", quote_currency: "BRL", rate_date: @date)

    assert lookup.same_currency?
    assert_equal BigDecimal("1"), lookup.exchange_rate.rate
    assert_empty HistoricalExchangeRate.all
  end

  test "returns direct rate before inverse" do
    create_rate(base_currency: "USD", quote_currency: "BRL", rate: "5")
    create_rate(base_currency: "BRL", quote_currency: "USD", rate: "0.1")

    lookup = @service.read(base_currency: "USD", quote_currency: "BRL", rate_date: @date)

    assert_equal BigDecimal("5"), lookup.exchange_rate.rate
    assert_not lookup.inverted
  end

  test "returns an exact inverse when direct rate is missing" do
    create_rate(base_currency: "BRL", quote_currency: "USD", rate: "0.2")

    lookup = @service.read(base_currency: "USD", quote_currency: "BRL", rate_date: @date)

    assert_equal BigDecimal("5"), lookup.exchange_rate.rate
    assert lookup.inverted
  end

  test "returns an explicit missing lookup" do
    assert @service.read(base_currency: "USD", quote_currency: "BRL", rate_date: @date).missing?
  end

  test "rejects future rate dates" do
    assert_raises(ArgumentError) do
      @service.read(base_currency: "USD", quote_currency: "BRL", rate_date: Date.current + 1)
    end
  end

  private

  def create_rate(base_currency:, quote_currency:, rate:)
    HistoricalExchangeRate.create!(
      base_currency:, quote_currency:, rate_date: @date, rate: BigDecimal(rate), provider: "test_provider",
      observed_at: Time.current, fetched_at: Time.current
    )
  end
end
