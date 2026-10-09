class PerformancesController < ApplicationController
  allow_unauthenticated_access

  def show
    @period_selection = Performance::PeriodSelection.for(period: params[:period])
    @selected_period = @period_selection.period
    @performance = Performance::Period.for(from: period_start, to: period_end)
    if @performance.available?
      @period_presenter = Performance::PeriodPresenter.new(@performance)
      @series = Performance::Series.for(from: period_start, to: period_end)
      @series_presenter = Performance::SeriesPresenter.new(@series)
      @benchmark_results = benchmark_results(reporting_currency: @performance.closing_valuation.market_value.currency.iso_code)
      @benchmark_chart_data = Performance::BenchmarkChartData.for(series: @series, benchmark_results: @benchmark_results)
    end
    @historical_data_backfill_pending = HistoricalDataBackfill.pending_for?(instruments: @performance.missing_instruments)
  end

  private

  def period_start
    @period_selection.from
  end

  def period_end
    @period_selection.to
  end

  def benchmark_results(reporting_currency:)
    exchange_rate_service = HistoricalExchangeRate::Service.new
    MarketBenchmark.order(:identifier).map do |benchmark|
      [ benchmark, Performance::Benchmark.for(benchmark:, from: period_start, to: period_end, reporting_currency:,
        exchange_rate_service:) ]
    end
  end
end
