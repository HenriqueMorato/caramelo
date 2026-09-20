require "test_helper"

class Performance::PeriodSelectionTest < ActiveSupport::TestCase
  test "normalizes supported and unsupported selections" do
    today = Date.new(2026, 9, 9)

    week = Performance::PeriodSelection.for(period: "week", today:)
    fallback = Performance::PeriodSelection.for(period: "unsupported", today:)

    assert_equal "week", week.period
    assert_equal today - 1.week, week.from
    assert_equal "month", fallback.period
    assert_equal today - 1.month, fallback.from
    assert_equal today, fallback.to
  end

  test "scopes all time to the selected instrument first trade" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)

    selection = Performance::PeriodSelection.for(period: "all", owner:, instrument:)

    assert_equal owner.trades.where(instrument:).minimum(:traded_on), selection.from
  end

  test "uses today for all time without trades" do
    owner = User.create!(
      email_address: "period-selection@example.com", password: "password",
      password_confirmation: "password", reporting_currency: "BRL"
    )
    today = Date.new(2026, 9, 9)

    selection = Performance::PeriodSelection.for(period: "all", owner:, today:)

    assert_equal today, selection.from
    assert_equal "Sep 09 – Sep 09", selection.date_range_label
  end

  test "uses the first income performance date for all time without trades" do
    owner = User.create!(
      email_address: "income-period-selection@example.com", password: "password",
      password_confirmation: "password", reporting_currency: "BRL"
    )
    instrument = Instrument.create!(
      ticker: "INCOMEPERIOD", exchange: "TEST", name: "Income period", currency: "BRL", asset_type: :stock
    )
    performance_on = Date.new(2026, 8, 20)
    CorporateAction.create!(
      user: owner, instrument:, kind: :dividend, status: :confirmed,
      paid_on: performance_on + 5.days, ex_date: performance_on,
      gross_amount_cents: 1_000, withholding_tax_cents: 0, net_amount_cents: 1_000,
      currency: "BRL", source: "manual"
    )

    selection = Performance::PeriodSelection.for(
      period: "all", owner:, instrument:, today: Date.new(2026, 9, 9)
    )

    assert_equal performance_on, selection.from
  end
end
