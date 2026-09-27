class ScanCorporateActionImportsJob < ApplicationJob
  queue_as :market_prices

  RETRY_ATTEMPTS = 3

  limits_concurrency key: ->(user_id:, source:, instrument_id:, **) {
    "corporate-action-imports:#{user_id}:#{source}:#{instrument_id || "all"}"
  },
  duration: 2.minutes, on_conflict: :block
  retry_on MarketData::YahooFinance::TransportError, MarketData::YahooFinance::RateLimited,
    MarketData::YahooFinance::ProviderUnavailable, wait: :polynomially_longer, attempts: RETRY_ATTEMPTS do |job, error|
      job.mark_scan_failed(error)
    end

  def perform(user_id:, from:, to:, source: "yahoo_finance", instrument_id: nil, scope: nil, scan_run_id: nil)
    prepare_scan_status(user_id:, from:, to:, source:, instrument_id:, scope:, scan_run_id:)
    return unless scan_tracked? ? CorporateActionImports::ScanStatus.start(scope: @scan_scope, run_id: @scan_run_id) : true

    user = User.find(user_id)
    instrument = traded_instrument_for(user, instrument_id) if instrument_id
    result = CorporateActionImports::Scan.call(
      user:, from: Date.iso8601(from.to_s), to: Date.iso8601(to.to_s), source:, instrument:, strict: true
    )
    complete_scan
    result
  rescue StandardError => error
    handle_scan_error(error) if scan_tracked?
    raise
  end

  def mark_scan_failed(error)
    return unless scan_tracked?

    fail_scan(error)
  end

  private

  def prepare_scan_status(user_id:, from:, to:, source:, instrument_id:, scope:, scan_run_id:)
    return unless scope.present? && scan_run_id.present?

    @scan_scope = scope
    @scan_run_id = scan_run_id
    @scan_refresh_path = CorporateActionImports::ScanStatus.path(
      from:, to:, source:, instrument_id:
    )
    expected_scope = CorporateActionImports::ScanStatus.scope(
      user: User.find(user_id), from:, to:, source:, instrument_id:
    )
    raise ArgumentError, "scan scope does not match its request" unless expected_scope == scope
  end

  def scan_tracked?
    @scan_scope.present? && @scan_run_id.present?
  end

  def complete_scan
    state = CorporateActionImports::ScanStatus.succeed(scope: @scan_scope, run_id: @scan_run_id)
    CorporateActionImports::ScanStatus.broadcast(
      scope: @scan_scope, refresh_path: @scan_refresh_path, reload: true
    ) if state
  end

  def handle_scan_error(error)
    if retryable_error?(error)
      CorporateActionImports::ScanStatus.retrying(scope: @scan_scope, run_id: @scan_run_id)
    else
      fail_scan(error)
    end
  end

  def fail_scan(error)
    state = CorporateActionImports::ScanStatus.fail(scope: @scan_scope, run_id: @scan_run_id, error:)
    CorporateActionImports::ScanStatus.broadcast(
      scope: @scan_scope, refresh_path: @scan_refresh_path
    ) if state
  end

  def retryable_error?(error)
    [
      MarketData::YahooFinance::TransportError,
      MarketData::YahooFinance::RateLimited,
      MarketData::YahooFinance::ProviderUnavailable
    ].any? { |error_class| error.is_a?(error_class) }
  end

  def traded_instrument_for(user, instrument_id)
    trade = user.trades.includes(:instrument).find_by(instrument_id: instrument_id)
    raise ActiveRecord::RecordNotFound, "instrument is not traded by this owner" unless trade

    trade.instrument
  end
end
