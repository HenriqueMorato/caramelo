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
end
