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
      @benchmark_results = MarketBenchmark.order(:identifier).map do |benchmark|
        [ benchmark, Performance::Benchmark.for(benchmark:, from: period_start, to: Date.current) ]
      end
      @benchmark_chart_data = @benchmark_results.filter_map do |benchmark, result|
        next unless result.available?

        values_by_date = result.observations.zip(result.cumulative_return_values).to_h { |observation, value| [ observation.observed_on, value.to_f * 100 ] }
        { identifier: benchmark.identifier, label: benchmark.name,
          values: @series.observations.map { |observation| values_by_date[observation.date] } }
      end
    end
    @historical_data_backfill_pending = HistoricalDataBackfill.pending_for?(instruments: @performance.missing_instruments)
  end

  private

  def period_start
    return User.owner.trades.minimum(:traded_on) || Date.current if @selected_period == "all"

    Date.current - PERIODS.fetch(@selected_period)
  end
end
