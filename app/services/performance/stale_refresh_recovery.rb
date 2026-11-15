module Performance
  class StaleRefreshRecovery
    STALE_AFTER = 5.minutes

    Result = Data.define(:recovered_count, :changed_count) do
      def recovered? = recovered_count.positive?
      def changed? = changed_count.positive?
    end

    def self.call(now: Time.current, stale_after: STALE_AFTER, queue_activity: MarketData::QueueActivity)
      new(now:, stale_after:, queue_activity:).call
    end

    def initialize(now:, stale_after:, queue_activity:)
      @now = now
      @stale_after = stale_after
      @queue_activity = queue_activity
    end

    def call
      outcomes = materializations.filter_map { |materialization| recover(materialization) }
      Result.new(
        recovered_count: outcomes.count(:recovered),
        changed_count: outcomes.length
      )
    end

    private

    attr_reader :now, :stale_after, :queue_activity

    def materializations
      PortfolioPerformanceMaterialization.includes(:user).to_a +
        InstrumentPerformanceMaterialization.includes(:user, :instrument).to_a
    end

    def recover(materialization)
      return false unless materialization.pending?

      instrument = materialization.respond_to?(:instrument) ? materialization.instrument : nil
      user = materialization.user
      currency = materialization.reporting_currency
      state = Performance::SeriesRefresh.read(user:, instrument:, reporting_currency: currency)
      return false if state&.failed?
      return false if Performance::SeriesRefresh.enqueue_in_flight?(
        user:, instrument:, reporting_currency: currency
      )
      return false if Performance::SeriesRefresh.synchronous_execution?(
        user:, instrument:, reporting_currency: currency
      )
      return false if active_job?(user:, instrument:, currency:)
      return false unless stale?(materialization:, state:)

      release_lease(user:, instrument:, currency:, state:)
      result = Performance::SeriesRefresh.enqueue(
        user:, instrument:, reporting_currency: currency,
        from: materialization.requested_from, to: materialization.requested_to, force: true
      )
      result == :queued ? :recovered : (result == :failed ? :changed : false)
    rescue StandardError => error
      Rails.error.report(
        error, handled: true,
        context: { source: "stale_performance_refresh_recovery", user_id: user&.id, instrument_id: instrument&.id }
      )
      false
    end

    def stale?(materialization:, state:)
      last_update = state&.updated_at || materialization.updated_at
      last_update <= now - stale_after
    end

    def release_lease(user:, instrument:, currency:, state:)
      token = Performance::SeriesRefresh.lease_token(user:, instrument:, reporting_currency: currency)
      return unless token

      if state&.active?
        Performance::SeriesRefresh.release_stale(
          user:, instrument:, reporting_currency: currency, token:, cutoff: now - stale_after
        )
      else
        Performance::SeriesRefresh.release_orphaned(
          user:, instrument:, reporting_currency: currency, token:
        )
      end
    end

    def active_job?(user:, instrument:, currency:)
      job_class = instrument ? BuildInstrumentPerformanceObservationsJob : BuildPortfolioPerformanceObservationsJob
      queue_activity.active_job?(class_name: job_class.name) do |arguments|
        arguments[:user_id].to_i == user.id &&
          arguments[:reporting_currency].to_s == currency &&
          (!instrument || arguments[:instrument_id].to_i == instrument.id)
      end
    end
  end
end
