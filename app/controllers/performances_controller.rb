class PerformancesController < ApplicationController
  allow_unauthenticated_access

  PERIODS = {
    "week" => 1.week,
    "month" => 1.month,
    "year" => 1.year,
    "all" => nil
  }.freeze

  def show
    @selected_period = params[:period].presence_in(PERIODS.keys) || "month"
    @performance = Performance::Period.for(from: period_start, to: Date.current)
    if @performance.available?
      @series = Performance::Series.for(from: period_start, to: Date.current)
      @series_presenter = Performance::SeriesPresenter.new(@series)
      @benchmark_results = benchmark_results
      @benchmark_chart_data = Performance::BenchmarkChartData.for(series: @series, benchmark_results: @benchmark_results)
    end
    @historical_data_backfill_pending = HistoricalDataBackfill.pending_for?(instruments: @performance.missing_instruments)
  end

  private

  def period_start
    return User.owner.trades.minimum(:traded_on) || Date.current if @selected_period == "all"

    Date.current - PERIODS.fetch(@selected_period)
  end

  def benchmark_results
    MarketBenchmark.order(:identifier).map do |benchmark|
      [ benchmark, Performance::Benchmark.for(benchmark:, from: period_start, to: Date.current) ]
    end
  end
end
