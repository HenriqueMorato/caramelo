class PrepareReportingCurrencyJob < ApplicationJob
  queue_as :market_prices

  limits_concurrency key: ->(user, currency:) { "reporting_currency:#{user.id}:#{currency}" },
    duration: 30.minutes, on_conflict: :discard
  discard_on ActiveJob::DeserializationError
  retry_on MarketData::YahooFinance::Error, ExchangeRate::InvalidValue,
    wait: :polynomially_longer, attempts: 3
  retry_on ActiveJob::EnqueueError, wait: 1.minute, attempts: 3

  def self.enqueue_for(user:)
    perform_later(user, currency: user.reporting_currency).present?
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { user_id: user.id })
    false
  end

  def perform(user, currency:)
    # Superseded requests need not fetch another currency's history.
    return unless user.reload.reporting_currency == currency

    ReportingCurrency::Preparation.new(user:, currency:).call
  end
end
