require "test_helper"

class ActivityHistoryTest < ActiveSupport::TestCase
  setup do
    CorporateAction.delete_all
    @trade = trades(:owner_voo_buy)
    @income = CorporateAction.create!(
      user: users(:owner), instrument: instruments(:petr4_bvmf), kind: :dividend,
      status: :confirmed, paid_on: @trade.traded_on, gross_amount_cents: 1_000,
      withholding_tax_cents: 0, net_amount_cents: 1_000, currency: "BRL", source: "manual"
    )
  end

  test "orders heterogeneous activity through a union all query" do
    occurred_at = Time.zone.parse("2026-08-12 12:00:00")
    @trade.update_columns(created_at: occurred_at)
    @income.update_columns(created_at: occurred_at)
    sql = []
    listener = ->(_name, _started, _finished, _id, payload) { sql << payload[:sql] }

    transactions = ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      history.transactions
    end

    assert_equal [ @trade, @income ], transactions
    assert sql.any? { |statement| statement.include?("UNION ALL") && statement.include?("ORDER BY") }
  end

  test "has the composite index used by instrument activity queries" do
    index = ActiveRecord::Base.connection.indexes(:corporate_actions).find do |candidate|
      candidate.columns == %w[user_id instrument_id paid_on]
    end

    assert index
  end

  test "filters each activity type in the database" do
    sql = []
    listener = ->(_name, _started, _finished, _id, payload) { sql << payload[:sql] }

    trade_transactions = ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      history(activity: "trades").transactions
    end
    income_transactions = ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      history(activity: "income").transactions
    end

    assert_equal [ @trade ], trade_transactions
    assert_equal [ @income ], income_transactions
    assert sql.none? { |statement| statement.include?("UNION ALL") }
    assert sql.grep(/ORDER BY/).any? { |statement| statement.include?('"trades"."traded_on" DESC') }
    assert sql.grep(/ORDER BY/).any? { |statement| statement.include?('"corporate_actions"."paid_on" DESC') }
  end

  test "keeps filters visible when the selected type is empty" do
    @income.destroy!

    filtered_history = history(activity: "income")

    assert_empty filtered_history.transactions
    assert filtered_history.any?
  end

  test "keeps filters visible when no trades match existing income" do
    @trade.destroy!

    filtered_history = history(activity: "trades")

    assert_empty filtered_history.transactions
    assert filtered_history.any?
  end

  test "reports a completely empty history" do
    @income.destroy!
    @trade.destroy!

    assert_not history.any?
  end

  private

  def history(activity: nil)
    ActivityHistory.new(
      trades: users(:owner).trades.where(id: @trade.id).includes(:instrument, :institution),
      income: users(:owner).corporate_actions.where(id: @income.id).includes(:instrument, :institution),
      activity:
    )
  end
end
