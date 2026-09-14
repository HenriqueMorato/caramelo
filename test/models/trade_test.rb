require "test_helper"

class TradeTest < ActiveSupport::TestCase
  test "generates an opaque stable URL reference" do
    trade = Trade.create!(valid_attributes)

    assert_match(/\Atxn-[a-zA-Z0-9]{12}\z/i, trade.slug)
    assert_no_changes -> { trade.reload.slug } do
      trade.update!(notes: "Updated without changing its URL")
    end
  end

  test "retries a generated reference collision once" do
    Trade.create!(valid_attributes.merge(slug: "txn-collision123"))
    trade = Trade.new(valid_attributes.merge(notes: "Another transaction"))
    trade.define_singleton_method(:slug_candidates) do
      [ "txn-collision123", "txn-freshcode456" ]
    end

    trade.save!

    assert_equal "txn-freshcode456", trade.slug
  end

  test "falls back to a UUID when the retry also collides" do
    with_stubbed_method(SecureRandom, :base58, ->(*) { "Collision123" }) do
      first = Trade.create!(valid_attributes)
      second = Trade.create!(valid_attributes.merge(notes: "Another transaction"))

      assert_equal "txn-collision123", first.slug
      assert_match(/\Atxn-collision123-[0-9a-f-]{36}\z/, second.slug)
      refute_equal first.slug, second.slug
    end
  end

  test "belongs to an owner and instrument with an optional institution" do
    trade = build_trade

    assert_equal users(:owner), trade.user
    assert_equal instruments(:petr4_bvmf), trade.instrument
    assert_equal institutions(:owner_xp), trade.institution
    assert_predicate trade, :valid?

    trade.institution = nil
    assert_predicate trade, :valid?
  end

  test "requires an institution owned by the trade owner" do
    trade = build_trade(institution: institutions(:other_owner))

    assert_predicate trade, :invalid?
    assert_includes trade.errors[:institution], "must belong to the trade owner"
  end

  test "limits side to buy or sell" do
    assert_predicate build_trade(side: "buy"), :valid?
    assert_predicate build_trade(side: "sell"), :valid?

    trade = build_trade(side: "transfer")

    assert_predicate trade, :invalid?
    assert_includes trade.errors[:side], "is not included in the list"
  end

  test "requires a trade date" do
    trade = build_trade(traded_on: nil)

    assert_predicate trade, :invalid?
    assert_includes trade.errors[:traded_on], "can't be blank"
  end

  test "stores a positive precise quantity" do
    trade = build_trade(quantity: BigDecimal("10.12345678"))
    trade.save!

    assert_equal BigDecimal("10.12345678"), trade.reload.quantity

    trade.quantity = 0
    assert_predicate trade, :invalid?

    trade.quantity = -1
    assert_predicate trade, :invalid?
  end

  test "stores unit price to eight decimal places and exposes fees as Money" do
    trade = build_trade(unit_price: BigDecimal("0.12345678"), fees_cents: 67)
    trade.save!

    assert_equal BigDecimal("0.12345678"), trade.reload.unit_price
    assert_instance_of Money, trade.fees
    assert_equal 67, trade.fees.fractional
    assert_equal "BRL", trade.fees.currency.iso_code
  end

  test "exposes exact analytical amounts separately from rounded Money values" do
    trade = build_trade(quantity: 1, unit_price: BigDecimal("0.0049"), fees_cents: 1)

    assert_equal BigDecimal("0.0049"), trade.gross_value_amount
    assert_equal BigDecimal("0.0149"), trade.total_amount
    assert_equal Money.from_cents(0, "BRL"), trade.gross_value
    assert_equal Money.from_cents(1, "BRL"), trade.total
  end

  test "normalizes currency and requires it to match the instrument" do
    trade = build_trade(currency: " brl ")

    assert_predicate trade, :valid?
    assert_equal "BRL", trade.currency

    trade.currency = "USD"
    assert_predicate trade, :invalid?
    assert_includes trade.errors[:currency], "must match the instrument currency"
  end

  test "requires a positive unit price and nonnegative fees" do
    trade = build_trade(unit_price: 0, fees_cents: -1)

    assert_predicate trade, :invalid?
    assert_includes trade.errors[:unit_price], "must be greater than 0"
    assert_includes trade.errors[:fees_cents], "must be greater than or equal to 0"

    trade = Trade.new(valid_attributes.except(:fees_cents))

    assert_predicate trade, :valid?
    assert_equal 0, trade.fees_cents
  end

  test "derives gross value and negative cash effect for buys" do
    trade = build_trade(quantity: BigDecimal("2.5"), unit_price: BigDecimal("10"), fees_cents: 125)

    assert_equal Money.from_cents(2_500, "BRL"), trade.gross_value
    assert_equal Money.from_cents(-2_625, "BRL"), trade.signed_cash_effect
  end

  test "derives gross value and positive cash effect for sells" do
    trade = build_trade(side: "sell", quantity: BigDecimal("2.5"), unit_price: BigDecimal("10"), fees_cents: 125)

    assert_equal Money.from_cents(2_500, "BRL"), trade.gross_value
    assert_equal Money.from_cents(2_375, "BRL"), trade.signed_cash_effect
  end

  test "derives a positive total including buy fees and subtracting sell fees" do
    buy = build_trade(quantity: 2, unit_price: BigDecimal("10"), fees_cents: 125)
    sell = build_trade(side: "sell", quantity: 2, unit_price: BigDecimal("10"), fees_cents: 125)

    assert_equal Money.from_cents(2_125, "BRL"), buy.total
    assert_equal Money.from_cents(1_875, "BRL"), sell.total
  end

  test "calculates a USD trade without converting it to the reporting currency" do
    trade = build_trade(
      instrument: instruments(:voo_arcx),
      institution: nil,
      quantity: 2,
      unit_price: BigDecimal("10.25"),
      fees_cents: 50,
      currency: "USD"
    )

    assert_predicate trade, :valid?
    assert_equal Money.from_cents(2_050, "USD"), trade.gross_value
    assert_equal Money.from_cents(2_100, "USD"), trade.total
    refute_equal Money.from_cents(2_100, "BRL"), trade.total
  end

  test "captures the owner reporting currency when a paid exchange rate is supplied" do
    trade = build_trade(
      instrument: instruments(:voo_arcx), institution: nil, currency: "USD",
      settlement_exchange_rate: "5.25"
    )

    assert_predicate trade, :valid?
    assert_equal "BRL", trade.settlement_currency
    assert_equal BigDecimal("5.25"), trade.settlement_exchange_rate
    assert_predicate trade, :explicit_settlement_conversion?
  end

  test "replaces an injected settlement currency with the owner reporting currency" do
    trade = build_trade(
      instrument: instruments(:voo_arcx), institution: nil, currency: "USD",
      settlement_currency: "EUR", settlement_exchange_rate: "5.25"
    )

    trade.save!

    assert_equal "BRL", trade.settlement_currency
  end

  test "preserves a captured settlement currency when the owner preference changes" do
    trade = build_trade(
      instrument: instruments(:voo_arcx), institution: nil, currency: "USD",
      settlement_exchange_rate: "5.25"
    )
    trade.save!
    trade.user.update!(reporting_currency: "EUR")

    trade.update!(settlement_exchange_rate: "5.3")

    assert_equal "BRL", trade.settlement_currency
  end

  test "clears the captured settlement currency with the paid exchange rate" do
    trade = build_trade(
      instrument: instruments(:voo_arcx), institution: nil, currency: "USD",
      settlement_exchange_rate: "5.25"
    )
    trade.save!

    trade.update!(settlement_exchange_rate: nil)

    assert_nil trade.settlement_currency
    assert_not trade.explicit_settlement_conversion?
  end

  test "rejects a paid exchange rate for a same-currency trade" do
    trade = build_trade(settlement_exchange_rate: "1")

    assert_predicate trade, :invalid?
    assert_includes trade.errors[:settlement_currency], "must differ from the instrument currency"
  end

  test "cannot infer a settlement currency without an owner" do
    trade = build_trade(
      user: nil, instrument: instruments(:voo_arcx), institution: nil,
      currency: "USD", settlement_exchange_rate: "5.25"
    )

    assert_predicate trade, :invalid?
    assert_nil trade.settlement_currency
  end

  test "normalizes blank notes to nil" do
    trade = build_trade(notes: "   ")

    assert_nil trade.notes
    assert_predicate trade, :valid?
  end

  test "does not invalidate performance when only notes change" do
    trade = trades(:owner_voo_buy)
    invalidations = []

    with_stubbed_invalidator(->(**arguments) { invalidations << arguments }) do
      trade.update!(notes: "Updated context")
    end

    assert_empty invalidations
  end

  test "orders trades in reverse chronology with newest records first" do
    older = build_trade(traded_on: Date.new(2026, 1, 10))
    older.save!
    newer = build_trade(traded_on: Date.new(2026, 1, 11))
    newer.save!

    assert_equal [ newer, older ], Trade.where(id: [ older.id, newer.id ]).reverse_chronological.to_a
  end

  test "instruments and institutions cannot be deleted while referenced" do
    trade = build_trade
    trade.save!

    assert_includes trade.user.trades, trade
    assert_includes trade.instrument.trades, trade
    assert_includes trade.institution.trades, trade
    assert_not trade.instrument.destroy
    assert_includes trade.instrument.errors[:base], "Cannot delete record because dependent trades exist"
    assert_not trade.institution.destroy
    assert_includes trade.institution.errors[:base], "Cannot delete record because dependent trades exist"
  end

  test "a referenced instrument cannot change currency" do
    trade = build_trade
    trade.save!
    instrument = trade.instrument

    instrument.currency = "USD"

    assert_predicate instrument, :invalid?
    assert_includes instrument.errors[:currency], "cannot change while trades exist"
  end

  test "database constraints reject invalid financial values" do
    attributes = {
      user_id: users(:owner).id,
      instrument_id: instruments(:petr4_bvmf).id,
      institution_id: institutions(:owner_xp).id,
      side: "buy",
      traded_on: Date.new(2026, 1, 10),
      quantity: 1,
      unit_price: BigDecimal("10"),
      fees_cents: 0,
      currency: "BRL",
      slug: "txn-invalid-trade",
      created_at: Time.current,
      updated_at: Time.current
    }

    {
      side: "transfer",
      quantity: 0,
      unit_price: 0,
      fees_cents: -1
    }.each do |attribute, invalid_value|
      assert_raises ActiveRecord::StatementInvalid do
        Trade.insert_all!([ attributes.merge(attribute => invalid_value) ])
      end
    end
  end

  test "reports a materialization enqueue failure" do
    trade = build_trade
    failure = RuntimeError.new("queue unavailable")
    reports = []

    with_stubbed_method(RefreshPositionMaterializationJob, :perform_later, ->(**) { raise failure }) do
      with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
        trade.send(:enqueue_position_materialization_refresh)
      end
    end

    assert_equal failure, reports.sole.first
    assert_equal({ handled: true, context: { trade_id: nil } }, reports.sole.second)
  end

  private

  def build_trade(attributes = {})
    Trade.new(valid_attributes.merge(attributes))
  end

  def valid_attributes
    {
      user: users(:owner),
      instrument: instruments(:petr4_bvmf),
      institution: institutions(:owner_xp),
      side: "buy",
      traded_on: Date.new(2026, 1, 10),
      quantity: BigDecimal("10"),
      unit_price: BigDecimal("32.10"),
      fees_cents: 150,
      currency: "BRL",
      notes: "Initial position"
    }
  end

  def with_stubbed_invalidator(replacement)
    original = Performance::ObservationInvalidator.method(:mark!)
    Performance::ObservationInvalidator.define_singleton_method(:mark!, replacement)
    yield
  ensure
    Performance::ObservationInvalidator.define_singleton_method(:mark!, original)
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
