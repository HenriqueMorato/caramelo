require "test_helper"

class ReportingCurrencyTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @owner = users(:owner)
    @instrument = instruments(:voo_arcx)
    @from = trades(:owner_voo_buy).traded_on
    @to = @from + 1
    create_close(@from, "600")
    create_close(@to, "620")
    %w[BRL EUR].zip(%w[5 0.9]).each do |currency, rate|
      [ @from, @to ].each { |date| create_rate(currency, rate, date) }
    end
  end

  test "values portfolio periods and charts in the owner currency without rewriting sources" do
    original_sources = source_records

    { "BRL" => "5", "USD" => "1", "EUR" => "0.9" }.each do |currency, rate|
      @owner.update!(reporting_currency: currency)
      multiplier = BigDecimal(rate)
      period = Performance::Period.for(from: @from, to: @to)
      Performance::ObservationBuilder.new(user: @owner).call(from: @from, to: @to)
      series = Performance::Series.for(from: @from, to: @to)

      assert_predicate period, :available?
      assert_equal Money.from_amount(1_550 * multiplier, currency), period.closing_valuation.market_value
      assert_equal Money.from_amount(50 * multiplier, currency), period.gain_loss
      assert_equal currency, period.net_cash_flow.currency.iso_code
      assert_equal period.closing_valuation.market_value, series.observations.last.market_value
      assert_equal period.gain_loss, series.observations.last.gain_loss
      assert_equal period.return_ratio, series.observations.last.return_ratio
    end

    assert_equal %w[BRL EUR USD], @owner.portfolio_performance_observations.distinct.order(:reporting_currency)
      .pluck(:reporting_currency)
    assert_equal original_sources, source_records
  end

  test "uses the supplied owner rather than the configured owner for period calculations" do
    other_owner = users(:two)
    other_owner.update!(reporting_currency: "EUR")

    period = Performance::Period.for(from: @from, to: @to, owner: other_owner)

    assert_predicate period, :empty?
    assert_equal Money.from_amount(0, "EUR"), period.closing_valuation.market_value
    assert_equal Money.from_amount(0, "EUR"), period.gain_loss
  end

  test "dashboard uses each supplied owner's currency for positions and totals" do
    @owner.update!(reporting_currency: "USD")
    other_owner = users(:two)
    other_owner.update!(reporting_currency: "EUR")
    other_owner.trades.create!(
      instrument: @instrument, traded_on: @from, side: :buy, quantity: 1, unit_price: 600, currency: "USD"
    )
    CurrentMarketPriceCache.new.write(instrument: @instrument, current_market_price: CurrentMarketPrice.new(
      unit_price: "620", currency: "USD", provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier,
      quoted_at: Time.current, fetched_at: Time.current
    ))
    ExchangeRateCache.new.write(exchange_rate: ExchangeRate::Rate.new(
      base_currency: "USD", quote_currency: "EUR", rate: BigDecimal("0.9"),
      observed_at: Time.current, fetched_at: Time.current,
      provider: ExchangeRate::Providers::YahooFinance::IDENTIFIER
    ))

    own_dashboard = Dashboard::Presenter.for(owner: @owner, today: @to)
    other_dashboard = Dashboard::Presenter.for(owner: other_owner, today: @to)

    assert_equal Money.from_amount(1_550, "USD"), own_dashboard.market_value
    assert_equal Money.from_amount(558, "EUR"), other_dashboard.market_value
    assert_equal other_dashboard.market_value, other_dashboard.positions.sole.valuation.market_value
    assert_equal other_dashboard.market_value, other_dashboard.performance.closing_valuation.market_value
  end

  test "aggregates mixed native holdings without relabeling their amounts" do
    brazilian = instruments(:petr4_bvmf)
    @owner.trades.create!(
      instrument: brazilian, traded_on: @from, side: :buy, quantity: 2, unit_price: 10, currency: "BRL"
    )
    DailyClosingPrice.create!(
      instrument: brazilian, trading_date: @to, close_price: "12", currency: "BRL",
      provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier, observed_at: Time.current
    )
    [ @from, @to ].each do |date|
      HistoricalExchangeRate.create!(
        base_currency: "BRL", quote_currency: "EUR", rate_date: date, rate: "0.18",
        provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER,
        observed_at: Time.current, fetched_at: Time.current
      )
    end

    { "BRL" => "7774", "USD" => "1554.8", "EUR" => "1399.32" }.each do |currency, amount|
      @owner.update!(reporting_currency: currency)

      result = Performance::Portfolio.for(valuation_date: @to)

      assert_equal Money.from_amount(BigDecimal(amount), currency), result.market_value
      assert_equal 2, result.position_results.size
    end
  end

  test "does not fall back to old currency observations when new FX is missing" do
    Performance::ObservationBuilder.new(user: @owner).call(from: @from, to: @to)
    @owner.update!(reporting_currency: "EUR")
    HistoricalExchangeRate.where(quote_currency: "EUR").delete_all

    period = Performance::Period.for(from: @from, to: @to)
    Performance::ObservationBuilder.new(user: @owner).call(from: @from, to: @to)
    series = Performance::Series.for(from: @from, to: @to)

    assert_predicate period, :missing?
    assert_nil period.gain_loss
    assert_predicate series, :missing?
    assert_nil series.observations.last.market_value
    assert @owner.portfolio_performance_observations.where(reporting_currency: "BRL").all?(&:available?)
  end

  test "performance presenter preserves the calculated currency after a preference change" do
    @owner.update!(reporting_currency: "EUR")
    performance = Performance::Portfolio.for(valuation_date: @to)
    @owner.update!(reporting_currency: "USD")

    presenter = Performance::Presenter.for(performance:, pending: false)

    assert_equal Money.from_amount(1_395, "EUR"), presenter.market_value
    assert_equal "EUR", presenter.cost_basis.currency.iso_code
    assert_equal "EUR", presenter.unrealized_gain.currency.iso_code
  end

  test "refresh leases and observations remain isolated when the preference changes" do
    assert_equal :queued, Performance::SeriesRefresh.enqueue(user: @owner, from: @from, to: @to)
    brl_job = enqueued_jobs.last
    @owner.update!(reporting_currency: "EUR")
    assert_nil Performance::SeriesRefresh.read(user: @owner)
    assert_equal :queued, Performance::SeriesRefresh.enqueue(user: @owner, from: @from, to: @to)

    assert_enqueued_jobs 2, only: BuildPortfolioPerformanceObservationsJob
    BuildPortfolioPerformanceObservationsJob.deserialize(brl_job).perform_now

    assert_equal "succeeded", Performance::SeriesRefresh.read(user: @owner, reporting_currency: "BRL").status
    assert_predicate Performance::SeriesRefresh.read(user: @owner), :active?
    assert_empty @owner.portfolio_performance_observations.where(reporting_currency: "EUR")
    assert_equal Money.from_amount(7_750, "BRL"), Performance::Series.for(
      user: @owner, from: @from, to: @to, reporting_currency: "BRL"
    ).observations.last.market_value
  end

  test "source changes invalidate existing currencies and the current preference" do
    Performance::ObservationBuilder.new(user: @owner).call(from: @from, to: @to)
    @owner.update!(reporting_currency: "EUR")

    Performance::ObservationInvalidator.mark!(user: @owner, from: @from)

    assert_equal %w[BRL EUR], @owner.portfolio_performance_materializations.order(:reporting_currency)
      .pluck(:reporting_currency)
    assert @owner.portfolio_performance_observations.all?(&:stale?)
    assert_equal "EUR", PortfolioPerformanceMaterialization.for(user: @owner).reporting_currency
  end

  private

  def create_close(date, price)
    DailyClosingPrice.create!(
      instrument: @instrument, trading_date: date, close_price: price, currency: "USD",
      provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier, observed_at: Time.current
    )
  end

  def create_rate(currency, rate, date)
    HistoricalExchangeRate.create!(
      base_currency: "USD", quote_currency: currency, rate_date: date, rate:,
      provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER,
      observed_at: Time.current, fetched_at: Time.current
    )
  end

  def source_records
    [ Trade, Instrument, DailyClosingPrice, HistoricalExchangeRate ].map do |model|
      model.order(:id).map(&:attributes)
    end
  end
end
