require "test_helper"

class MarketData::TargetResolverTest < ActiveSupport::TestCase
  test "resolves an owner-traded instrument target" do
    target = MarketData::TargetResolver.call(
      attributes: { kind: "current_price", record_id: instruments(:voo_arcx).id },
      owner: users(:owner)
    )

    assert_equal :current_price, target.kind
    assert_equal instruments(:voo_arcx).id, target.record_id
  end

  test "rejects an instrument without an owner trade" do
    assert_raises(ActiveRecord::RecordNotFound) do
      MarketData::TargetResolver.call(
        attributes: { kind: "current_price", record_id: instruments(:petr4_bvmf).id },
        owner: users(:owner)
      )
    end
  end

  test "resolves an owner currency target" do
    target = MarketData::TargetResolver.call(
      attributes: { kind: "historical_exchange_rates", base_currency: "USD", quote_currency: "BRL" },
      owner: users(:owner)
    )

    assert_equal :historical_exchange_rates, target.kind
    assert_equal "USD", target.base_currency
    assert_equal "BRL", target.quote_currency
  end

  test "rejects an untrusted reporting-currency owner id" do
    assert_raises(ActiveRecord::RecordNotFound) do
      MarketData::TargetResolver.call(
        attributes: { kind: "portfolio_performance", record_id: users(:one).id },
        owner: users(:owner)
      )
    end
  end

  test "rejects a currency pair unrelated to the reporting currency" do
    assert_raises(ActiveRecord::RecordNotFound) do
      MarketData::TargetResolver.call(
        attributes: { kind: "historical_exchange_rates", base_currency: "USD", quote_currency: "EUR" },
        owner: users(:owner)
      )
    end
  end

  test "ignores caller-supplied provider values" do
    target = MarketData::TargetResolver.call(
      attributes: {
        kind: "historical_exchange_rates", base_currency: "USD", quote_currency: "BRL",
        provider: "untrusted"
      },
      owner: users(:owner)
    )

    assert_equal MarketData::YahooFinance::FX_CONFIGURATION.identifier, target.provider
  end

  test "resolves a benchmark target" do
    benchmark = MarketBenchmark.create!(
      identifier: "RESOLVE", name: "Resolver benchmark", kind: :price, currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^RESOLVE"
    )

    target = MarketData::TargetResolver.call(
      attributes: { kind: "benchmark_observations", record_id: benchmark.id }, owner: users(:owner)
    )

    assert_equal benchmark.id, target.record_id
  end

  test "allows the owner reporting currency target" do
    target = MarketData::TargetResolver.call(
      attributes: { kind: "portfolio_performance", record_id: users(:owner).id }, owner: users(:owner)
    )

    assert_equal :portfolio_performance, target.kind
  end

  test "resolves a traded instrument performance currency view" do
    target = MarketData::TargetResolver.call(
      attributes: {
        kind: "instrument_performance", record_id: instruments(:voo_arcx).id, quote_currency: "usd"
      },
      owner: users(:owner)
    )

    assert_equal :instrument_performance, target.kind
    assert_equal instruments(:voo_arcx).id, target.record_id
    assert_equal "USD", target.quote_currency
  end

  test "resolves an existing additional instrument performance currency view" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    InstrumentPerformanceMaterialization.for(user: owner, instrument:, reporting_currency: "EUR")

    target = MarketData::TargetResolver.call(
      attributes: { kind: "instrument_performance", record_id: instrument.id, quote_currency: "EUR" }, owner:
    )

    assert_equal "EUR", target.quote_currency
  end

  test "rejects an unmaintained instrument performance currency view" do
    assert_raises(ActiveRecord::RecordNotFound) do
      MarketData::TargetResolver.call(
        attributes: {
          kind: "instrument_performance", record_id: instruments(:voo_arcx).id, quote_currency: "JPY"
        },
        owner: users(:owner)
      )
    end
  end

  test "rejects instrument performance for an untraded instrument" do
    assert_raises(ActiveRecord::RecordNotFound) do
      MarketData::TargetResolver.call(
        attributes: {
          kind: "instrument_performance", record_id: instruments(:petr4_bvmf).id, quote_currency: "BRL"
        },
        owner: users(:owner)
      )
    end
  end

  test "ignores an unrecognized target kind from a test double" do
    fake_target = Struct.new(:kind).new(:unknown)
    with_stubbed_method(MarketData::Target, :new, ->(**) { fake_target }) do
      assert_equal fake_target, MarketData::TargetResolver.call(
        attributes: { kind: "unknown" }, owner: users(:owner)
      )
    end
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(method_name) { |*args, **kwargs| original.call(*args, **kwargs) }
  end
end
