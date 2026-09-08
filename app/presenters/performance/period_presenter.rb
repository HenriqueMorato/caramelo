module Performance
  class PeriodPresenter
    include FinancialDisplay

    attr_reader :period

    def initialize(period)
      @period = period
      freeze
    end

    def return_label
      signed_percentage(period.return_ratio) if period.return_available?
    end

    def gain_loss_label
      signed_money(period.gain_loss)
    end

    def gain_loss_arrow
      trend_arrow(period.gain_loss_amount)
    end

    def gain_loss_color_class
      trend_color_class(period.gain_loss_amount)
    end

    def unrealized_gain_color_class
      period.closing_valuation.unrealized_gain.negative? ? "text-guava" : "text-positive-on-dark"
    end
  end
end
