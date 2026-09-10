module Performance
  class PeriodSelection
    PERIODS = {
      "week" => 1.week,
      "month" => 1.month,
      "year" => 1.year,
      "all" => nil
    }.freeze

    attr_reader :period, :from, :to

    def self.for(period:, owner: User.owner, instrument: nil, today: Date.current)
      selected = period.to_s.presence_in(PERIODS.keys) || "month"
      new(period: selected, owner:, instrument:, today:)
    end

    def self.date_range_label(from:, to:)
      if from.year == to.year
        "#{I18n.l(from, format: :short)} – #{I18n.l(to, format: :short)}"
      else
        format = I18n.t("date.formats.range_with_year")
        "#{I18n.l(from, format:)} – #{I18n.l(to, format:)}"
      end
    end

    def initialize(period:, owner:, instrument:, today:)
      @period = period
      @to = today
      trades = owner.trades
      trades = trades.where(instrument:) if instrument
      @from = period == "all" ? trades.minimum(:traded_on) || today : today - PERIODS.fetch(period)
    end

    def date_range_label
      self.class.date_range_label(from:, to:)
    end
  end
end
