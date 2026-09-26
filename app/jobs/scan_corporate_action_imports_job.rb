class ScanCorporateActionImportsJob < ApplicationJob
  queue_as :market_prices

  RETRY_ATTEMPTS = 3

  limits_concurrency key: ->(user_id:, source:, **) { "corporate-action-imports:#{user_id}:#{source}" },
    duration: 2.minutes, on_conflict: :block
  retry_on MarketData::YahooFinance::TransportError, MarketData::YahooFinance::RateLimited,
    MarketData::YahooFinance::ProviderUnavailable, wait: :polynomially_longer, attempts: RETRY_ATTEMPTS

  def perform(user_id:, from:, to:, source: "yahoo_finance", instrument_id: nil)
    user = User.find(user_id)
    instrument = Instrument.find_by(id: instrument_id) if instrument_id
    CorporateActionImports::Scan.call(
      user:, from: Date.iso8601(from.to_s), to: Date.iso8601(to.to_s), source:, instrument:, strict: true
    )
  end
end
