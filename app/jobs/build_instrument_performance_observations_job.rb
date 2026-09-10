class BuildInstrumentPerformanceObservationsJob < ApplicationJob
  queue_as :default

  limits_concurrency key: ->(arguments) {
    values = arguments.symbolize_keys
    "instrument_performance:#{values[:user_id]}:#{values[:instrument_id]}:#{values[:reporting_currency]}"
  }, duration: 30.minutes, on_conflict: :block

  def perform(user_id:, instrument_id:, reporting_currency:, lease_token:)
    @user = User.find(user_id)
    @target_instrument = Instrument.find(instrument_id)
    @reporting_currency = reporting_currency
    @lease_token = lease_token
    @materialization = InstrumentPerformanceMaterialization.for(
      user:, instrument: target_instrument, reporting_currency:
    )
    requested_range = materialization.requested_range
    return release_lease unless requested_range

    build(from: requested_range.begin, to: requested_range.end)
  end

  private

  attr_reader :user, :target_instrument, :reporting_currency, :lease_token, :materialization

  def build(from:, to:)
    refresh(:running, from:, to:)
    store = InstrumentPerformance::ObservationStore.new(
      user:, instrument: target_instrument, reporting_currency:
    )
    result = Performance::ObservationBuilder.new(
      user:, instrument: target_instrument, store:, materialization:
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
  end

  def refresh(status, **arguments)
    Performance::SeriesRefresh.public_send(
      status, user:, instrument: target_instrument, reporting_currency:, token: lease_token, **arguments
    )
  end

  def release_lease
    Performance::SeriesRefresh.release(
      user:, instrument: target_instrument, reporting_currency:, token: lease_token
    )
    nil
  end

  def resume_pending_materialization
    materialization.reload
    return unless materialization.pending?

    Performance::SeriesRefresh.enqueue(
      user:, instrument: target_instrument, from: materialization.requested_from,
      to: materialization.requested_to, reporting_currency:
    )
  end
end
