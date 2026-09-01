module Performance
  class Series
    # One end-of-day portfolio observation. Each field has a distinct role:
    # `date` identifies the trading day; `market_value_amount` preserves the
    # precise portfolio total for calculations; `market_value` formats that
    # total for display; `invested_amount` and `invested_value` expose net
    # invested capital (buys less sale proceeds) in precise and display forms;
    # `gain_loss_amount`
    # and `gain_loss` expose the precise and formatted change from the selected
    # period start; `return_ratio` is the cash-flow-adjusted percentage change;
    # and `status` distinguishes a complete observation from missing history.
    Observation = Data.define(
      :date, :market_value_amount, :market_value, :invested_amount, :invested_value,
      :gain_loss_amount, :gain_loss, :return_ratio, :status
    ) do
      def available? = status == :available
      def missing? = status == :missing
    end

    # The complete requested range, including missing weekdays. `from` and `to`
    # preserve the requested boundaries; `observations` holds one result per
    # weekday; and `status` indicates whether the range is available, incomplete,
    # or genuinely empty.
    Result = Data.define(:from, :to, :observations, :status) do
      def available? = status == :available
      def missing? = status == :missing
      def empty? = status == :empty

      def missing_dates = observations.filter_map { |observation| observation.date if observation.missing? }
    end

    def self.for(from:, to:, portfolio: Portfolio)
      new(from:, to:, portfolio:).calculate
    end

    def initialize(from:, to:, portfolio:)
      @from = from
      @to = to
      @portfolio = portfolio
    end

    def calculate
      validate_range!
      observations = dates.map { |date| observation_for(date) }
      status = if observations.empty?
        :empty
      elsif observations.any?(&:missing?)
        :missing
      else
        :available
      end
      Result.new(from:, to:, observations:, status:)
    end

    private

    attr_reader :from, :to, :portfolio

    def dates
      (from..to).reject { |date| date.saturday? || date.sunday? }
    end

    def observation_for(date)
      period = Performance::Period.for(from:, to: date, portfolio: memoized_portfolio)
      valuation = period.closing_valuation
      invested_amount = decimal(valuation.position_results.filter_map(&:net_cash_flow_amount).sum)
      currency = valuation.market_value&.currency || reporting_currency
      Observation.new(
        date:, market_value_amount: valuation.market_value_amount, market_value: valuation.market_value,
        invested_amount:, invested_value: Money.from_amount(invested_amount, currency),
        gain_loss_amount: period.gain_loss_amount, gain_loss: period.gain_loss,
        return_ratio: period.return_ratio, status: period.status
      )
    end

    def memoized_portfolio
      @memoized_portfolio ||= MemoizedPortfolio.new(portfolio)
    end

    def validate_range!
      unless from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current
        raise ArgumentError, "period must use dates from the past in chronological order"
      end
    end

    def reporting_currency
      Rails.configuration.x.local_folio.reporting_currency
    end

    def decimal(value)
      BigDecimal(value.to_r, Position::ANALYTICAL_DECIMAL_PRECISION)
    end

    class MemoizedPortfolio
      def initialize(portfolio)
        @portfolio = portfolio
        @valuations = {}
      end

      def for(valuation_date:)
        @valuations[valuation_date] ||= @portfolio.for(valuation_date:)
      end
    end
  end
end
