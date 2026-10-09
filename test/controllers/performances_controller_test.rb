require "test_helper"

class PerformancesControllerTest < ActionDispatch::IntegrationTest
  test "shows a selected period with gains from persisted historical data" do
    Trade.where(user: User.owner).delete_all
    from = Date.current - 1.week
    instrument = Instrument.create!(ticker: "PERF", exchange: "BVMF", name: "Performance stock", currency: "BRL")
    create_trade(instrument:, traded_on: from)
    create_trade(instrument:, traded_on: Date.current)
    create_daily_close(instrument:, date: from, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")

    get performance_url(period: "week")

    assert_response :success
    assert_select "h1", "How the pack is doing."
    assert_select "a[href=?]", performance_path(period: "week"), "Week"
    assert_select "body", /R\$22,00/
    assert_select "body", /R\$2,00/
    assert_select "body", /20\.00%/
    assert_select "body", /R\$10,00/

    patch money_visibility_url, params: { hidden: "true" }
    get performance_url(period: "week")

    assert_includes response.body, ApplicationHelper::MONEY_MASK
    refute_includes response.body, "R$22,00"
    refute_includes response.body, "R$2,00"
  end

  test "shows an explicit unavailable state when historical data is missing" do
    Trade.where(user: User.owner).delete_all
    instrument = Instrument.create!(ticker: "MISS", exchange: "BVMF", name: "Missing stock", currency: "BRL")
    create_trade(instrument:, traded_on: Date.current - 1.month)
    HistoricalDataBackfill.delete_all

    get performance_url

    assert_response :success
    assert_select "h2", "Historical data unavailable"
    assert_select "p", /never substitutes a current quote/
  end

  test "shows a pending state while historical data is being backfilled" do
    Trade.where(user: User.owner).delete_all
    instrument = Instrument.create!(ticker: "WAIT", exchange: "BVMF", name: "Pending stock", currency: "BRL")
    trade = create_trade(instrument:, traded_on: Date.current - 1.month)
    HistoricalDataBackfill.create!(instrument:, currency: trade.currency, from_date: trade.traded_on)

    get performance_url

    assert_response :success
    assert_select "h2", "Historical data is loading"
    assert_select "p", /Check back shortly/
    assert HistoricalDataBackfill.exists?(instrument:, currency: trade.currency)
  end

  test "uses the first trade date for the all-time period" do
    Trade.where(user: User.owner).delete_all
    first_trade_date = Date.current - 2.weeks
    instrument = Instrument.create!(ticker: "ALLP", exchange: "BVMF", name: "All-time performance stock", currency: "BRL")
    create_trade(instrument:, traded_on: first_trade_date)
    create_daily_close(instrument:, date: first_trade_date, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")

    get performance_url(period: "all")

    assert_response :success
    assert_select "body", /R\$11,00/
    assert_select "body", /10\.00%/
  end

  test "shows available benchmark returns for the selected period" do
    Trade.where(user: User.owner).delete_all
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
    from = Date.current - 1.week
    instrument = Instrument.create!(ticker: "BENCH", exchange: "BVMF", name: "Benchmark stock", currency: "BRL")
    create_trade(instrument:, traded_on: from)
    create_trade(instrument:, traded_on: Date.current)
    create_daily_close(instrument:, date: from, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")
    benchmark = MarketBenchmark.create!(identifier: "IBOV", name: "Ibovespa", kind: "price", currency: "BRL", provider: "bacen", provider_identifier: "IBOV")
    benchmark.observations.create!(observed_on: from, value: "100", currency: "BRL", provider: "bacen", observed_at: Time.current)
    benchmark.observations.create!(observed_on: Date.current, value: "105", currency: "BRL", provider: "bacen", observed_at: Time.current)

    get performance_url(period: "week")

    assert_select "#market-benchmarks-heading", "Market benchmarks"
    assert_select "body", /\+5\.00%/
  end

  test "converts a total-return global benchmark into the reporting currency" do
    Trade.where(user: User.owner).delete_all
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
    from = Date.current - 1.week
    instrument = Instrument.create!(ticker: "GLOBAL", exchange: "BVMF", name: "Global benchmark stock", currency: "BRL")
    create_trade(instrument:, traded_on: from)
    create_trade(instrument:, traded_on: Date.current)
    create_daily_close(instrument:, date: from, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")
    benchmark = MarketBenchmark.create!(identifier: "ACWI_IMI_NET", name: "MSCI ACWI IMI (Net Total Return proxy)",
      kind: "total_return", currency: "USD", provider: "yahoo_finance", provider_identifier: "IMID.L",
      return_convention: "net")
    benchmark.observations.create!(observed_on: from, value: "100", currency: "USD", provider: "yahoo_finance", observed_at: Time.current)
    benchmark.observations.create!(observed_on: Date.current, value: "110", currency: "USD", provider: "yahoo_finance", observed_at: Time.current)
    [ [ from, "5" ], [ Date.current, "5.5" ] ].each do |date, rate|
      HistoricalExchangeRate.create!(base_currency: "USD", quote_currency: "BRL", rate_date: date, rate:,
        provider: "yahoo_finance_fx", observed_at: Time.current, fetched_at: Time.current)
    end

    get performance_url(period: "week")

    assert_select "body", /MSCI ACWI IMI \(Net Total Return proxy\)/
    assert_select "body", /\+21\.00%/
  end

  test "includes a global total-return benchmark in the seeded definitions" do
    attributes = MarketBenchmark::DEFAULTS.find { |item| item.fetch(:identifier) == "ACWI_IMI_NET" }

    assert_equal "total_return", attributes.fetch(:kind)
    assert_equal "net", attributes.fetch(:return_convention)
    assert_equal "USD", attributes.fetch(:currency)
    assert_equal "IMID.L", attributes.fetch(:provider_identifier)
  end

  test "keeps internal market observation dates out of the summary" do
    Trade.where(user: User.owner).delete_all
    instrument = Instrument.create!(ticker: "FXDATE", exchange: "XNAS", name: "Foreign performance stock", currency: "USD")
    create_trade(instrument:, traded_on: Date.current)
    create_daily_close(instrument:, date: Date.current, close_price: "10")
    HistoricalExchangeRate.create!(
      base_currency: "USD", quote_currency: "BRL", rate_date: Date.current - 1, rate: "5",
      provider: MarketData::YahooFinance::FX_CONFIGURATION.identifier,
      observed_at: Time.current, fetched_at: Time.current
    )

    get performance_url(period: "all")

    assert_response :success
    assert_select "body", text: /Market prices through/, count: 0
    assert_select "body", text: /FX rates through/, count: 0
  end

  test "shows the empty state without owner trades" do
    Trade.where(user: User.owner).delete_all

    get performance_url

    assert_response :success
    assert_select "p", "No performance yet"
    assert_select "a[href=?]", new_trade_path
  end

  private

  def create_trade(instrument:, traded_on:)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on:, quantity: 1, unit_price: "10", fees_cents: 0, currency: instrument.currency
    )
  end

  def create_daily_close(instrument:, date:, close_price:)
    DailyClosingPrice.create!(
      instrument:, trading_date: date, close_price:, currency: instrument.currency, provider: "yahoo_finance", observed_at: Time.current
    )
  end
end
