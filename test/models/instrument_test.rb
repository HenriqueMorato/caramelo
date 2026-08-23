require "test_helper"

class InstrumentTest < ActiveSupport::TestCase
  test "belongs to an owner and defaults to BRL" do
    instrument = Instrument.new(user: users(:owner), ticker: "BOVA11", name: "iShares Ibovespa")

    assert_equal users(:owner), instrument.user
    assert_equal "BRL", instrument.currency
    assert_predicate instrument, :valid?
  end

  test "normalizes and requires ticker and name" do
    instrument = Instrument.new(
      user: users(:owner),
      ticker: "  bova11  ",
      name: "  iShares   Ibovespa  ",
      currency: " brl "
    )

    assert_equal "BOVA11", instrument.ticker
    assert_equal "iShares Ibovespa", instrument.name
    assert_equal "BRL", instrument.currency

    instrument.ticker = ""
    instrument.name = ""

    assert_predicate instrument, :invalid?
    assert_includes instrument.errors[:ticker], "can't be blank"
    assert_includes instrument.errors[:name], "can't be blank"
  end

  test "prevents case-insensitive duplicate tickers for one owner" do
    duplicate = Instrument.new(user: users(:owner), ticker: "petr4", name: "Duplicate")

    assert_predicate duplicate, :invalid?
    assert_includes duplicate.errors[:ticker], "has already been taken"
  end

  test "enforces case-insensitive ticker uniqueness in the database" do
    now = Time.current
    attributes = {
      user_id: users(:owner).id,
      ticker: "BOVA11",
      name: "iShares Ibovespa",
      currency: "BRL",
      created_at: now,
      updated_at: now
    }

    Instrument.insert_all!([ attributes ])

    assert_raises ActiveRecord::RecordNotUnique do
      Instrument.insert_all!([ attributes.merge(ticker: "bova11") ])
    end
  end

  test "allows the same ticker for different owners" do
    instrument = Instrument.new(user: users(:one), ticker: "VOO", name: "Vanguard S&P 500 ETF", currency: "USD")

    assert_predicate instrument, :valid?
  end

  test "accepts supported currencies and rejects invalid codes" do
    instrument = Instrument.new(user: users(:owner), ticker: "AAPL", name: "Apple", currency: "usd")

    assert_predicate instrument, :valid?
    assert_equal "USD", instrument.currency

    instrument.currency = "ZZZ"
    assert_predicate instrument, :invalid?

    instrument.currency = "BTC"
    assert_predicate instrument, :invalid?
  end

  test "sorts instruments by ticker" do
    assert_equal [ instruments(:owner_petr4), instruments(:owner_voo) ], users(:owner).instruments.alphabetical.to_a
  end

  test "deletes an unused instrument" do
    instrument = Instrument.create!(user: users(:owner), ticker: "AAPL", name: "Apple", currency: "USD")

    assert_difference("Instrument.count", -1) { instrument.destroy }
    assert_predicate instrument, :destroyed?
  end
end
