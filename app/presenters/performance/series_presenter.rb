module Performance
  class SeriesPresenter
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

    private

    attr_reader :series
  end
end
