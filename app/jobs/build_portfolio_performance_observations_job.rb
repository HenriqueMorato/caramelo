class BuildPortfolioPerformanceObservationsJob < ApplicationJob
  queue_as :default

  limits_concurrency key: ->(*) { "portfolio_performance" }, duration: 30.minutes, on_conflict: :block

  def perform(user_id:, reporting_currency:, lease_token:)
    @user = User.find(user_id)
    @reporting_currency = reporting_currency
    @lease_token = lease_token
    @materialization = PortfolioPerformanceMaterialization.for(user:, reporting_currency:)
    requested_range = materialization.requested_range
    return finish_obsolete_refresh unless requested_range

    build(from: requested_range.begin, to: requested_range.end)
  end

  private

  attr_reader :user, :reporting_currency, :lease_token, :materialization

  def build(from:, to:)
    Performance::SeriesRefresh.running(user:, from:, to:, reporting_currency:, token: lease_token)
    store = Performance::ObservationStore.new(user:, reporting_currency:)
    result = Performance::ObservationBuilder.new(user:, store:, materialization:).call(from:, to:)
    materialization.complete!(source_generation: result.source_generation, from:, to:)
    Performance::SeriesRefresh.succeeded(user:, from:, to:, reporting_currency:, token: lease_token)
    result
  rescue StandardError => error
    Performance::SeriesRefresh.failed(user:, from:, to:, reporting_currency:, error:, token: lease_token)
    raise
  ensure
    release_lease
    resume_pending_materialization
  end

  def release_lease
    Performance::SeriesRefresh.release(user:, reporting_currency:, token: lease_token)
    nil
  end

  def finish_obsolete_refresh
    state = Performance::SeriesRefresh.read(user:, reporting_currency:)
    Performance::SeriesRefresh.succeeded(
      user:, reporting_currency:, token: lease_token, from: state.from, to: state.to
    ) if state&.active?
    release_lease
  end

  def resume_pending_materialization
    materialization.reload
    return unless materialization.pending?

    Performance::SeriesRefresh.enqueue(
      user:,
      from: materialization.requested_from,
      to: materialization.requested_to,
      reporting_currency:
    )
  end
end
