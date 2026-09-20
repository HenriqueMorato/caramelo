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
      unless period == "all"
        @from = today - PERIODS.fetch(period)
        return
      end

      trades = owner.trades
      trades = trades.where(instrument:) if instrument
      actions = owner.corporate_actions.effective_on_or_before(today)
      actions = actions.where(instrument:) if instrument
      first_activity = [
        trades.where(traded_on: ..today).minimum(:traded_on),
        actions.minimum_performance_on
      ].compact.min
      @from = first_activity || today
    end

    def date_range_label
      self.class.date_range_label(from:, to:)
    end
  end
end
