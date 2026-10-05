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

  def perform(user_id:, from:, to:, source: CorporateActionImports::Providers::YAHOO_FINANCE, instrument_id: nil, scope: nil, scan_run_id: nil,
    automation_scan_id: nil, automation_run_id: nil)
    prepare_scan_status(user_id:, from:, to:, source:, instrument_id:, scope:, scan_run_id:)
    prepare_automation_scan(
      user_id:, instrument_id:, source:, from:, to:, automation_scan_id:, automation_run_id:
    )
    return if automation_tracked? && !@automation_scan.current_run?(@automation_run_id)
    return unless scan_tracked? ? CorporateActionImports::ScanStatus.start(scope: @scan_scope, run_id: @scan_run_id) : true
    return if automation_tracked? && !@automation_scan.start!(@automation_run_id)

    user = User.find(user_id)
    instrument = traded_instrument_for(user, instrument_id) if instrument_id
    result = CorporateActionImports::Scan.call(
      user:, from: Date.iso8601(from.to_s), to: Date.iso8601(to.to_s), source:, instrument:, strict: true,
      fence: automation_fence
    )
    complete_scan
    complete_automation_scan
    result
  rescue CorporateActionImports::Scan::Superseded => error
    fail_scan(error) if scan_tracked?
    nil
  rescue StandardError => error
    handle_scan_error(error) if scan_tracked?
    handle_automation_scan_error(error)
    raise
  end

  def mark_scan_failed(error)
    prepare_automation_scan_from_arguments unless automation_tracked?
    return unless scan_tracked?

    fail_scan(error)
    fail_automation_scan(error)
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

  def automation_tracked?
    @automation_scan.present? && @automation_run_id.present?
  end

  def complete_scan
    state = CorporateActionImports::ScanStatus.succeed(scope: @scan_scope, run_id: @scan_run_id)
    CorporateActionImports::ScanStatus.broadcast(
      scope: @scan_scope, refresh_path: @scan_refresh_path, reload: true
    ) if state
  end

  def complete_automation_scan
    return unless automation_tracked?

    completed = @automation_scan.complete!(@automation_run_id, through: Date.iso8601(@automation_to.to_s))
    broadcast_automation_health if completed
  end

  def handle_automation_scan_error(error)
    return unless automation_tracked?
    return if retryable_error?(error)

    fail_automation_scan(error)
  end

  def fail_automation_scan(error)
    return unless automation_tracked?

    failed = @automation_scan.fail!(@automation_run_id, error:)
    broadcast_automation_health if failed
  end

  def broadcast_automation_health
    MarketData::HealthReportBroadcaster.refresh
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { source: "corporate_action_scan_health_broadcast" })
  end

  def automation_fence
    return unless automation_tracked?

    ->(&block) { @automation_scan.with_current_run(@automation_run_id, &block) }
  end

  def prepare_automation_scan(user_id:, instrument_id:, source:, from:, to:, automation_scan_id:, automation_run_id:)
    return if automation_scan_id.blank? && automation_run_id.blank?
    raise ArgumentError, "automation scan arguments must be supplied together" if automation_scan_id.blank? || automation_run_id.blank?

    @automation_scan = CorporateActionImportScan.find(automation_scan_id)
    @automation_run_id = automation_run_id.to_s
    @automation_to = @automation_scan.requested_to
    raise ArgumentError, "automation scan has no requested range" unless @automation_to
    requested_from = Date.iso8601(from.to_s)
    requested_to = Date.iso8601(to.to_s)
    matches_request = @automation_scan.user_id == Integer(user_id) &&
      @automation_scan.instrument_id == Integer(instrument_id) &&
      @automation_scan.source == source.to_s.strip.downcase &&
      @automation_scan.requested_from == requested_from &&
      @automation_scan.requested_to == requested_to
    raise ArgumentError, "automation scan does not match its request" unless matches_request
  end

  def prepare_automation_scan_from_arguments
    arguments = self.arguments.first.to_h.symbolize_keys
    prepare_automation_scan(
      user_id: arguments[:user_id], instrument_id: arguments[:instrument_id], source: arguments[:source],
      from: arguments[:from], to: arguments[:to],
      automation_scan_id: arguments[:automation_scan_id],
      automation_run_id: arguments[:automation_run_id]
    )
  rescue ArgumentError, ActiveRecord::RecordNotFound
    nil
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
