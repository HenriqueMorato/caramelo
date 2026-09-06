require "test_helper"

class MarketData::RecoveryLeaseTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @target = MarketData::Target.new(kind: :current_price, record_id: instruments(:voo_arcx).id)
  end

  test "allows one lease and blocks a second lease for the same target" do
    first = MarketData::RecoveryLease.acquire(target: @target)
    second = MarketData::RecoveryLease.acquire(target: @target)

    assert_predicate first, :active?
    assert_nil second
    assert_equal first.token, MarketData::RecoveryLease.current(target: @target).token
  end

  test "only the owner token can release a lease" do
    lease = MarketData::RecoveryLease.acquire(target: @target)

    MarketData::RecoveryLease.release(target: @target, token: "other")
    assert MarketData::RecoveryLease.current(target: @target)

    MarketData::RecoveryLease.release(target: @target, token: lease.token)
    assert_nil MarketData::RecoveryLease.current(target: @target)
  end
end
