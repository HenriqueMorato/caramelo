require "test_helper"

class Trades::SettlementValueTest < ActiveSupport::TestCase
  setup do
    @trade = trades(:owner_voo_buy)
    @rates = FakeExchangeRates.new
  end

  test "keeps the native amount when reporting in the instrument currency" do
    @trade.update!(settlement_exchange_rate: "5.25")

    result = calculate(reporting_currency: "USD")

    assert_predicate result, :available?
    assert_equal BigDecimal("1529"), BigDecimal(result.amount, Position::ANALYTICAL_DECIMAL_PRECISION)
    assert_empty @rates.requests
  end

  test "uses the paid exchange rate in its captured settlement currency" do
    @trade.update!(settlement_exchange_rate: "5.25")

    result = calculate(reporting_currency: "BRL")

    assert_predicate result, :available?
    assert_equal "BRL", result.currency
    assert_equal BigDecimal("8027.25"), BigDecimal(result.amount, Position::ANALYTICAL_DECIMAL_PRECISION)
    assert_nil result.exchange_rate_lookup
    assert_empty @rates.requests
  end

  test "converts an actual settled value into a later reporting currency" do
    @trade.update!(settlement_exchange_rate: "5.25")
    @rates.add("BRL", "EUR", @trade.traded_on, "0.16")

    result = calculate(reporting_currency: "EUR")

    assert_predicate result, :available?
    assert_equal BigDecimal("1284.36"), BigDecimal(result.amount, Position::ANALYTICAL_DECIMAL_PRECISION)
    assert_equal [ [ "BRL", "EUR", @trade.traded_on ] ], @rates.requests
  end

  test "falls back to historical trade-date FX without a paid rate" do
    @rates.add("USD", "BRL", @trade.traded_on, "5.1")

    result = calculate(reporting_currency: "BRL")

    assert_predicate result, :available?
    assert_equal BigDecimal("7797.9"), BigDecimal(result.amount, Position::ANALYTICAL_DECIMAL_PRECISION)
    assert_equal [ [ "USD", "BRL", @trade.traded_on ] ], @rates.requests
  end

  test "reports missing when required historical FX is unavailable" do
    result = calculate(reporting_currency: "BRL")

    assert_predicate result, :missing?
    assert_nil result.amount
    assert_equal "BRL", result.currency
    assert_predicate result.exchange_rate_lookup, :missing?
  end

  private

  def calculate(reporting_currency:)
    Trades::SettlementValue.for(trade: @trade, reporting_currency:, exchange_rates: @rates)
  end

  class FakeExchangeRates
    attr_reader :requests

    def initialize
      @lookups = {}
      @requests = []
    end

    def add(base_currency, quote_currency, rate_date, rate)
      resolved = HistoricalExchangeRate::ResolvedRate.new(
        base_currency:, quote_currency:, rate_date:, rate: BigDecimal(rate), provider: "test",
        observed_at: Time.current, fetched_at: Time.current
      )
      @lookups[[ base_currency, quote_currency, rate_date ]] = HistoricalExchangeRate::Lookup.new(
        exchange_rate: resolved, status: :available, inverted: false
      )
    end

    def read(base_currency:, quote_currency:, rate_date:)
      @requests << [ base_currency, quote_currency, rate_date ]
      @lookups.fetch(
        [ base_currency, quote_currency, rate_date ],
        HistoricalExchangeRate::Lookup.new(exchange_rate: nil, status: :missing, inverted: false)
      )
    end
  end
end
