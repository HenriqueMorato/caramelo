require "test_helper"

class InstrumentTest < ActiveSupport::TestCase
  test "defaults to BVMF and BRL" do
    instrument = Instrument.new(ticker: "BOVA11", name: "iShares Ibovespa")

    assert_equal "BVMF", instrument.exchange
    assert_equal "BRL", instrument.currency
    assert_equal "other", instrument.asset_type
    assert_predicate instrument, :valid?
  end

  test "supports the global instrument categories" do
    instrument = Instrument.new(ticker: "BTC", exchange: "XNAS", name: "Bitcoin", currency: "USD", asset_type: :crypto)

    assert_predicate instrument, :valid?
    assert_predicate instrument, :crypto?

    instrument.asset_type = "invalid"
    assert_predicate instrument, :invalid?
    assert_includes instrument.errors[:asset_type], "is not included in the list"
  end

  test "normalizes and requires ticker, exchange, and name" do
    instrument = Instrument.new(
      ticker: "  bova11  ",
      exchange: " xnas ",
      name: "  iShares   Ibovespa  ",
      currency: " brl "
    )

    assert_equal "BOVA11", instrument.ticker
    assert_equal "XNAS", instrument.exchange
    assert_equal "iShares Ibovespa", instrument.name
    assert_equal "BRL", instrument.currency

    instrument.ticker = ""
    instrument.exchange = ""
    instrument.name = ""

    assert_predicate instrument, :invalid?
    assert_includes instrument.errors[:ticker], "can't be blank"
    assert_includes instrument.errors[:exchange], "can't be blank"
    assert_includes instrument.errors[:name], "can't be blank"
  end

  test "prevents case-insensitive duplicate tickers on one exchange" do
    duplicate = Instrument.new(ticker: "petr4", exchange: "bvmf", name: "Duplicate")

    assert_predicate duplicate, :invalid?
    assert_includes duplicate.errors[:ticker], "has already been taken"
  end

  test "enforces case-insensitive exchange and ticker uniqueness in the database" do
    now = Time.current
    attributes = {
      ticker: "BOVA11",
      exchange: "BVMF",
      name: "iShares Ibovespa",
      currency: "BRL",
      created_at: now,
      updated_at: now
    }

    Instrument.insert_all!([ attributes ])

    assert_raises ActiveRecord::RecordNotUnique do
      Instrument.insert_all!([ attributes.merge(ticker: "bova11", exchange: "bvmf") ])
    end
  end

  test "allows the same ticker on different exchanges" do
    instrument = Instrument.new(ticker: "PETR4", exchange: "XNAS", name: "Different listing", currency: "USD")

    assert_predicate instrument, :valid?
  end

  test "requires a four-character market identifier code" do
    instrument = Instrument.new(ticker: "AAPL", exchange: "BAD", name: "Apple", currency: "USD")

    assert_predicate instrument, :invalid?
    assert_includes instrument.errors[:exchange], "is invalid"

    instrument.exchange = "xnas"
    assert_predicate instrument, :valid?
    assert_equal "XNAS", instrument.exchange
  end

  test "accepts supported currencies and rejects invalid codes" do
    instrument = Instrument.new(ticker: "AAPL", exchange: "XNAS", name: "Apple", currency: "usd")

    assert_predicate instrument, :valid?
    assert_equal "USD", instrument.currency

    instrument.currency = "ZZZ"
    assert_predicate instrument, :invalid?

    instrument.currency = "BTC"
    assert_predicate instrument, :invalid?
  end

  test "sorts instruments by ticker and exchange" do
    assert_equal [ instruments(:petr4_bvmf), instruments(:voo_arcx) ], Instrument.alphabetical.to_a
  end

  test "deletes an unused instrument" do
    instrument = Instrument.create!(ticker: "AAPL", exchange: "XNAS", name: "Apple", currency: "USD")

    assert_difference("Instrument.count", -1) { instrument.destroy }
    assert_predicate instrument, :destroyed?
  end
end
