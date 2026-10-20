class BuildInstrumentPerformanceObservationsJob < ApplicationJob
  queue_as :default

  limits_concurrency key: ->(arguments) {
    values = arguments.symbolize_keys
    "instrument_performance:#{values[:user_id]}:#{values[:instrument_id]}:#{values[:reporting_currency]}"
  }, duration: 30.minutes, on_conflict: :block

  def perform(user_id:, instrument_id:, reporting_currency:, lease_token:, refetch_dependencies: false,
    refetch_full_range: false)
    @user = User.find(user_id)
    @target_instrument = Instrument.find(instrument_id)
    @reporting_currency = reporting_currency
    @lease_token = lease_token
    @refetch_dependencies = refetch_dependencies
    @refetch_full_range = refetch_full_range
    @materialization = InstrumentPerformanceMaterialization.for(
      user:, instrument: target_instrument, reporting_currency:
    )
    requested_range = materialization.requested_range
    return finish_obsolete_refresh unless requested_range

    build(from: requested_range.begin, to: requested_range.end)
  end

  private

  attr_reader :user, :target_instrument, :reporting_currency, :lease_token, :materialization,
    :refetch_dependencies, :refetch_full_range

  def build(from:, to:)
    refresh(:running, from:, to:, phase: refetch_dependencies ? "fetching" : "rebuilding")
    broadcast_health if refetch_dependencies
    fetch_dependencies(from:, to:) if refetch_dependencies
    refresh(:running, from:, to:, phase: "rebuilding") if refetch_dependencies
    broadcast_health if refetch_dependencies
    store = InstrumentPerformance::ObservationStore.new(
      user:, instrument: target_instrument, reporting_currency:
    )
    result = Performance::ObservationBuilder.new(
      user:, instrument: target_instrument, store:, materialization:,
      progress: -> {
        Performance::SeriesRefresh.heartbeat!(
          user:, instrument: target_instrument, reporting_currency:, from:, to:, token: lease_token,
          phase: "rebuilding"
        )
      }
    ).call(from:, to:)
    materialization.complete!(source_generation: result.source_generation, from:, to:)
    refresh(:succeeded, from:, to:)
    result
  rescue StandardError => error
    refresh(:failed, from:, to:, error:)
    raise
  ensure
    release_lease
    resume_pending_materialization
    broadcast_health
  end

  def refresh(status, **arguments)
    Performance::SeriesRefresh.public_send(
      status, user:, instrument: target_instrument, reporting_currency:, token: lease_token, **arguments
    )
  end

  def fetch_dependencies(from:, to:)
    Performance::HistoricalDependencyFetcher.new(
      user:, instrument: target_instrument, reporting_currency:,
      progress: ->(_message) {
        Performance::SeriesRefresh.heartbeat!(
          user:, instrument: target_instrument, reporting_currency:, from:, to:, token: lease_token,
          phase: "fetching"
        )
      }
    ).call(from:, to:, refetch_full_range:)
  end

  def release_lease
    Performance::SeriesRefresh.release(
      user:, instrument: target_instrument, reporting_currency:, token: lease_token
    )
    nil
  end

  def finish_obsolete_refresh
    state = Performance::SeriesRefresh.read(user:, instrument: target_instrument, reporting_currency:)
    refresh(:succeeded, from: state.from, to: state.to) if state&.active?
    release_lease
  end

  def resume_pending_materialization
    materialization.reload
    return unless materialization.pending?

    Performance::SeriesRefresh.enqueue(
      user:, instrument: target_instrument, from: materialization.requested_from,
      to: materialization.requested_to, reporting_currency:
    )
  end

  def broadcast_health
    MarketData::HealthReportBroadcaster.refresh
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { source: "instrument_performance_health_broadcast" })
  end
end
