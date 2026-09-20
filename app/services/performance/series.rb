module Performance
  class Series
    # One calendar-day chart value. Exact amounts back display Money values;
    # `return_ratio` retains Modified Dietz precision; and `status` distinguishes
    # fresh, stale, source-missing, and not-yet-built observations.
    Observation = Data.define(
      :date, :market_value_amount, :market_value, :invested_amount, :invested_value,
      :gain_loss_amount, :gain_loss, :return_ratio, :gain_on_cost_ratio, :status
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
      def stale_values? = observations.any?(&:stale?)
      def queued? = refresh_status == :queued
      def refreshing? = %i[queued active].include?(refresh_status)
      def displayable? = observations.any? { |observation| observation.market_value_amount }

      def missing_dates
        observations.filter_map { |observation| observation.date if observation.missing? }
      end
    end

    def self.for(from:, to:, user: User.owner, instrument: nil, store: nil, refresher: SeriesRefresh,
      materialization: nil, reporting_currency: user.reporting_currency)
      materialization ||= materialization_for(user:, instrument:, reporting_currency:)
      store ||= store_for(user:, instrument:, reporting_currency: materialization.reporting_currency)
      new(from:, to:, user:, instrument:, store:, refresher:, materialization:).calculate
    end

    def self.materialization_for(user:, instrument:, reporting_currency:)
      if instrument
        InstrumentPerformanceMaterialization.for(user:, instrument:, reporting_currency:)
      else
        PortfolioPerformanceMaterialization.for(user:, reporting_currency:)
      end
    end

    def self.store_for(user:, instrument:, reporting_currency:)
      if instrument
        InstrumentPerformance::ObservationStore.new(user:, instrument:, reporting_currency:)
      else
        ObservationStore.new(user:, reporting_currency:)
      end
    end
    private_class_method :materialization_for, :store_for

    def initialize(from:, to:, user:, instrument:, store:, refresher:, materialization:)
      @from = from
      @to = to
      @user = user
      @instrument = instrument
      @store = store
      @refresher = refresher
      @materialization = materialization
    end

    def calculate
      validate_range!
      @records = store.read(from:, to:)
      @refresh_status = enqueue_refresh
      materialization.reload if refresh_status
      @observations = build_observations
      Result.new(from:, to:, observations:, status: result_status, refresh_status:)
    end

    private

    attr_reader :from, :to, :user, :instrument, :store, :refresher, :materialization,
      :records, :observations, :refresh_status

    def dates
      (from..to).to_a
    end

    def enqueue_refresh
      dirty_dates = dates.select do |date|
        record = records[date]
        record.nil? || stale_record?(record)
      end
      return if dirty_dates.empty?

      attributes = { user:, from: dirty_dates.first, to: dirty_dates.last, reporting_currency: }
      attributes[:instrument] = instrument if instrument
      refresher.enqueue(**attributes)
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
      invested_amount = display_basis_amount(record)
      gain_loss_amount = gain_loss_for(record, opening)
      return_ratio = return_ratio_for(date:, record:, opening:, gain_loss_amount:)
      gain_on_cost_ratio = instrument_gain_on_cost_ratio(record)
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
        gain_on_cost_ratio:,
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
        gain_on_cost_ratio: nil,
        status:
      )
    end

    def display_basis_amount(record)
      return record.cost_basis_amount if instrument

      record.net_cash_flow_amount
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
      return decimal("0") if date == from && usable?(record)
      return if gain_loss_amount.nil?

      capital = weighted_capital(date:, record:, opening:)
      return if capital.zero?

      decimal(gain_loss_amount / capital)
    end

    def instrument_gain_on_cost_ratio(record)
      return unless instrument
      return if record.invested_amount.zero?

      decimal(
        (record.realized_gain_amount + record.unrealized_gain_amount + record.investment_income_amount) /
          record.invested_amount
      )
    end

    def weighted_capital(date:, record:, opening:)
      # Endpoint cumulative totals preserve the timing of every intervening trade;
      # an unavailable close between these endpoints does not erase its cash flows.
      flow_total = record.cash_flow_total - opening.cash_flow_total
      dated_flow_total = record.dated_cash_flow_total - opening.dated_cash_flow_total
      duration = date.jd - from.jd
      weighted_flows = (date.jd * flow_total - dated_flow_total) / duration
      opening.market_value_amount.to_r + weighted_flows
    end

    def result_status
      return :failed if refresh_status == :failed
      return :pending if observations.all?(&:pending?)
      return :partial if observations.any?(&:pending?)
      return :partial if observations.any?(&:missing?) && observations.any? { |item| !item.missing? }
      return :missing if observations.any?(&:missing?)
      return :stale if observations.any?(&:stale?)
      return :empty if records.values.all?(&:empty?)

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
