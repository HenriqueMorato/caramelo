module Performance
  class SeriesPresenter
    include FinancialDisplay

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
        invested_value_label: I18n.t("performances.show.Net invested"),
        return_label: I18n.t("performances.show.Return"),
        currency:,
        locale: I18n.locale
      }
    end

    private

    attr_reader :series

    def performance_label(ratio)
      "#{trend_arrow(ratio)} #{signed_percentage(ratio)}" if ratio
    end
  end
end
