module Performance
  class Series
    # One calendar-day chart value. Exact amounts back display Money values;
    # `return_ratio` retains Modified Dietz precision; and `status` distinguishes
    # fresh, stale, source-missing, and not-yet-built observations.
    Observation = Data.define(
      :date, :market_value_amount, :market_value, :invested_amount, :invested_value,
      :gain_loss_amount, :gain_loss, :return_ratio, :status
    ) do
      def available? = status == :available
      def missing? = %i[missing pending].include?(status)
      def pending? = status == :pending
      def stale? = status == :stale
    end

    # The requested range and its build state. `observations` always retains one
    # item per calendar date, allowing charts and accessible tables to expose
    # gaps without inventing zero values.
    Result = Data.define(:from, :to, :observations, :status, :refresh_status) do
      def available? = status == :available
      def missing? = status == :missing
      def empty? = status == :empty
      def pending? = status == :pending
      def partial? = status == :partial
      def stale? = status == :stale
      def failed? = status == :failed
      def refreshing? = %i[queued active].include?(refresh_status)
      def displayable? = observations.filter_map(&:market_value_amount).any?

      def missing_dates
        observations.filter_map { |observation| observation.date if observation.missing? }
      end
    end

    def self.for(from:, to:, user: User.owner, store: nil, refresher: SeriesRefresh,
      materialization: nil, reporting_currency: Rails.configuration.x.local_folio.reporting_currency)
      store ||= ObservationStore.new(user:, reporting_currency:)
      materialization ||= PortfolioPerformanceMaterialization.for(user:, reporting_currency:)
      new(from:, to:, user:, store:, refresher:, materialization:).calculate
    end

    def initialize(from:, to:, user:, store:, refresher:, materialization:)
      @from = from
      @to = to
      @user = user
      @store = store
      @refresher = refresher
      @materialization = materialization
    end

    def calculate
      validate_range!
      @records = store.read(from:, to:)
      @refresh_status = enqueue_refresh if rebuild_needed?
      materialization.reload if refresh_status
      @observations = build_observations
      Result.new(from:, to:, observations:, status: result_status, refresh_status:)
    end

    private

    attr_reader :from, :to, :user, :store, :refresher, :materialization,
      :records, :observations, :refresh_status

    def dates
      (from..to).to_a
    end

    def rebuild_needed?
      dates.any? { |date| records[date].nil? || stale_record?(records[date]) }
    end

    def enqueue_refresh
      dirty_dates = dates.select { |date| records[date].nil? || stale_record?(records[date]) }
      refresher.enqueue(user:, from: dirty_dates.first, to: dirty_dates.last, reporting_currency:)
    end

    def build_observations
      opening = records[from]
      dates.map do |date|
        observation_for(date:, record: records[date], opening:)
      end
    end

    def observation_for(date:, record:, opening:)
      return unavailable_observation(date, :pending) unless record
      return unavailable_observation(date, :missing) if record.missing?

      market_value_amount = record.market_value_amount
      invested_amount = record.net_cash_flow_amount
      gain_loss_amount = gain_loss_for(record, opening)
      return_ratio = return_ratio_for(date:, record:, opening:, gain_loss_amount:)
      status = stale_record?(record) ? :stale : :available

      Observation.new(
        date:,
        market_value_amount:,
        market_value: money(market_value_amount),
        invested_amount:,
        invested_value: money(invested_amount),
        gain_loss_amount:,
        gain_loss: money(gain_loss_amount),
        return_ratio:,
        status:
      )
    end

    def unavailable_observation(date, status)
      Observation.new(
        date:,
        market_value_amount: nil,
        market_value: nil,
        invested_amount: nil,
        invested_value: nil,
        gain_loss_amount: nil,
        gain_loss: nil,
        return_ratio: nil,
        status:
      )
    end

    def gain_loss_for(record, opening)
      return unless usable?(opening) && comparable_endpoints?(record, opening)

      decimal(
        record.market_value_amount - opening.market_value_amount -
          decimal(record.cash_flow_total - opening.cash_flow_total)
      )
    end

    def comparable_endpoints?(record, opening)
      return true if record.source_generation == opening.source_generation

      # Partial publication can mix pre-edit and rebuilt amounts. Keep their
      # known values visible, but never label that mixture a calculated return.
      !stale_record?(record) && !stale_record?(opening)
    end

    def return_ratio_for(date:, record:, opening:, gain_loss_amount:)
      return if date == from || gain_loss_amount.nil?

      # Endpoint cumulative totals preserve the timing of every intervening trade;
      # an unavailable close between these endpoints does not erase its cash flows.
      flow_total = record.cash_flow_total - opening.cash_flow_total
      dated_flow_total = record.dated_cash_flow_total - opening.dated_cash_flow_total
      duration = date.jd - from.jd
      weighted_flows = (date.jd * flow_total - dated_flow_total) / duration
      weighted_capital = opening.market_value_amount.to_r + weighted_flows
      return if weighted_capital.zero?

      decimal(gain_loss_amount / weighted_capital)
    end

    def result_status
      return :failed if refresh_status == :failed
      return :pending if observations.all?(&:pending?)
      return :partial if observations.any?(&:pending?)
      return :partial if observations.any?(&:missing?) && observations.any? { |item| !item.missing? }
      return :missing if observations.any?(&:missing?)
      return :stale if observations.any?(&:stale?)
      return :empty if observations.all? { |observation| observation.market_value_amount == 0 }

      :available
    end

    def usable?(record)
      record && !record.missing? && record.market_value_amount && record.net_cash_flow_amount
    end

    def stale_record?(record)
      return true if record.stale?
      return false unless materialization.pending?
      return false unless materialization.requested_range.cover?(record.observed_on)

      record.source_generation != materialization.source_generation
    end

    def money(amount)
      Money.from_amount(amount, reporting_currency) if amount
    end

    def reporting_currency
      materialization.reporting_currency
    end

    def decimal(value)
      BigDecimal(value.to_r, Position::ANALYTICAL_DECIMAL_PRECISION)
    end

    def validate_range!
      return if from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current

      raise ArgumentError, "period must use dates from the past in chronological order"
    end
  end
end
