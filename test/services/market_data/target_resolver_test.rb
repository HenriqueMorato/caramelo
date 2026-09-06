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
