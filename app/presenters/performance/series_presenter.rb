module Performance
  class SeriesPresenter
    include FinancialDisplay

    # Copy shown for one portfolio-history state.
    StatusCopy = Data.define(:title, :explanation)

    def initialize(series)
      @series = series
    end

    def date_range_label
      if series.from.year == series.to.year
        "#{I18n.l(series.from, format: :short)} – #{I18n.l(series.to, format: :short)}"
      else
        format = I18n.t("date.formats.range_with_year")
        "#{I18n.l(series.from, format:)} – #{I18n.l(series.to, format:)}"
      end
    end

    def chart_data(benchmarks:, currency:)
      {
        labels: series.observations.map { |item| I18n.l(item.date, format: :short) },
        values: series.observations.map { |item| item.market_value_amount&.to_f },
        invested_values: series.observations.map { |item| item.invested_amount&.to_f },
        formatted_values: series.observations.map { |item| item.market_value&.format },
        formatted_invested_values: series.observations.map { |item| item.invested_value&.format },
        formatted_performances: series.observations.map { |item| performance_label(item.return_ratio) },
        performance_ratios: series.observations.map(&:return_ratio),
        benchmarks:,
        portfolio_value_label: I18n.t("performances.show.Portfolio value"),
        portfolio_return_label: I18n.t("performances.show.Portfolio return"),
        invested_value_label: I18n.t("performances.show.Net invested"),
        return_label: I18n.t("performances.show.Return"),
        currency:,
        locale: I18n.locale
      }
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
