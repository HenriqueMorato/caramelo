class PrepareReportingCurrencyJob < ApplicationJob
  queue_as :market_prices

  limits_concurrency key: ->(user, currency:, **) { "reporting_currency:#{user.id}:#{currency}" },
    duration: 30.minutes, on_conflict: :block
  discard_on ActiveJob::DeserializationError
  retry_on MarketData::YahooFinance::Error, ExchangeRate::InvalidValue,
    wait: :polynomially_longer, attempts: 3
  retry_on ActiveJob::EnqueueError, wait: 1.minute, attempts: 3

  def self.enqueue_for(user:)
    currency = CurrencyCode.normalize(user.reporting_currency)
    run_id = SecureRandom.uuid
    scope = refresh_scope(user:, currency:)
    RefreshStatus::Tracker.enqueue(scope:, run_id:, supersede: true)
    job = perform_later(user, currency:, run_id:)
    return true if job.present?

    error = ActiveJob::EnqueueError.new("reporting currency preparation could not be enqueued")
    RefreshStatus::Tracker.fail(scope:, error:, run_id:)
    false
  rescue StandardError => error
    RefreshStatus::Tracker.fail(scope:, error:, run_id:) if scope && run_id
    Rails.error.report(error, handled: true, context: { user_id: user.id })
    false
  end

  def perform(user, currency:, run_id: nil)
    # Superseded requests need not fetch another currency's history.
    unless user.reload.reporting_currency == currency
      complete_superseded_run(user:, currency:, run_id:)
      return
    end

    run_id ||= SecureRandom.uuid
    ReportingCurrency::Preparation.new(user:, currency:, run_id:).call
  end

  def self.refresh_scope(user:, currency:)
    "reporting_currency:#{user.id}:#{currency}"
  end

  private

  def complete_superseded_run(user:, currency:, run_id:)
    return unless run_id

    scope = self.class.refresh_scope(user:, currency:)
    state = RefreshStatus::State.read(scope)
    return unless state&.run_id == run_id

    RefreshStatus::Tracker.perform(scope:, run_id:, total_count: 0) { }
  end
end
