module Performance
  class SeriesPresenter
    include FinancialDisplay

    # Copy shown for one portfolio-history state.
    StatusCopy = Data.define(:title, :explanation)

    def initialize(series)
      @series = series
    end

    def date_range_label
      Performance::PeriodSelection.date_range_label(from: series.from, to: series.to)
    end

    def chart_data(benchmarks:, currency:, performance_ratios: nil)
      performance_ratios ||= series.observations.map(&:return_ratio)
      {
        labels: series.observations.map { |item| I18n.l(item.date, format: :short) },
        values: series.observations.map { |item| item.market_value_amount&.to_f },
        invested_values: series.observations.map { |item| item.invested_amount&.to_f },
        formatted_values: series.observations.map { |item| item.market_value&.format },
        formatted_invested_values: series.observations.map { |item| item.invested_value&.format },
        formatted_performances: performance_ratios.map { |ratio| performance_label(ratio) },
        performance_ratios:,
        benchmarks:,
        portfolio_value_label: I18n.t("performances.show.Portfolio value"),
        portfolio_return_label: I18n.t("performances.show.Portfolio return"),
        invested_value_label: I18n.t("performances.show.Net invested"),
        return_label: I18n.t("performances.show.Return"),
        currency:,
        locale: I18n.locale
      }
    end

    def instrument_chart_data(currency:)
      chart_data(benchmarks: [], currency:).merge(
        portfolio_value_label: I18n.t("instruments.show.Position value"),
        portfolio_return_label: I18n.t("instruments.show.return_methodologies.modified_dietz.label"),
        invested_value_label: I18n.t("instruments.show.Cost basis"),
        return_label: I18n.t("instruments.show.Return"),
        gain_on_cost_return_label: I18n.t("instruments.show.return_methodologies.gain_on_cost.label"),
        gain_on_cost_performance_ratios: series.observations.map(&:gain_on_cost_ratio)
      )
    end

    def stale_status_copy
      @stale_status_copy ||= if series.queued?
        status_copy(
          I18n.t("performances.show.Portfolio history update is waiting"),
          I18n.t("performances.show.Portfolio history update is waiting explanation")
        )
      elsif series.refreshing?
        status_copy(
          I18n.t("performances.show.Portfolio history is refreshing"),
          I18n.t("performances.show.Portfolio history is refreshing explanation")
        )
      else
        status_copy(
          I18n.t("performances.show.Portfolio history may be out of date"),
          I18n.t("performances.show.Portfolio history may be out of date explanation")
        )
      end
    end

    private

    attr_reader :series

    def status_copy(title, explanation)
      StatusCopy.new(title:, explanation:)
    end

    def performance_label(ratio)
      "#{trend_arrow(ratio)} #{signed_percentage(ratio)}" if ratio
    end
  end
end
