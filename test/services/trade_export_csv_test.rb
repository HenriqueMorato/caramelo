require "test_helper"
require "csv"

class TradeExportCsvTest < ActiveSupport::TestCase
  test "exports the owner's trades with stable exact fields" do
    csv = TradeExport::Csv.call(user: users(:owner))
    rows = CSV.parse(csv, headers: true)

    assert_equal TradeExport::Csv::HEADERS, rows.headers
    assert_equal 1, rows.length
    assert_equal "2.5", rows.first["quantity"]
    assert_equal "611.2", rows.first["unit_price"]
    assert_equal "100", rows.first["fees_subunits"]
    assert_equal "USD", rows.first["fees_currency"]
    assert_equal "Long-term allocation.", rows.first["notes"]
    assert_includes csv, "\r\n"
  end

  test "exports an empty owner as headers only" do
    user = User.create!(email_address: "empty-export@example.com", password: "password123")

    rows = CSV.parse(TradeExport::Csv.call(user:), headers: true)

    assert_equal TradeExport::Csv::HEADERS, rows.headers
    assert_empty rows
  end

  test "orders rows by trade date and id and preserves optional blanks" do
    owner = users(:owner)
    instrument = instruments(:petr4_bvmf)
    first = owner.trades.create!(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: BigDecimal("0.12500000"), unit_price: BigDecimal("31.87000000"), fees_cents: 0, currency: "BRL")
    second = owner.trades.create!(instrument:, side: :sell, traded_on: Date.new(2026, 1, 2), quantity: 1, unit_price: 32, fees_cents: 0, currency: "BRL")

    rows = CSV.parse(TradeExport::Csv.call(user: owner), headers: true)

    ordered_rows = []
    rows.each { |row| ordered_rows << row }
    selected_rows = ordered_rows.select { |row| [ first.id.to_s, second.id.to_s ].include?(row["trade_id"]) }
    assert_equal [ first.id.to_s, second.id.to_s ], selected_rows.map { |row| row["trade_id"] }
    assert_nil selected_rows.last["institution_name"]
    assert_nil selected_rows.last["settlement_currency"]
  end

  test "protects formula-like text while leaving numeric values unchanged" do
    trade = trades(:owner_voo_buy)
    trade.update!(notes: "=HYPERLINK(\"https://example.com\")")

    row = CSV.parse(TradeExport::Csv.call(user: users(:owner)), headers: true).first

    assert_equal "'=HYPERLINK(\"https://example.com\")", row["notes"]
    assert_equal "2.5", row["quantity"]
  end
end
