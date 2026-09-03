class CurrentMarketPriceRefreshesController < ApplicationController
  allow_unauthenticated_access
  REFRESH_SCOPE = "manual_current_market_prices"
  MANUAL_COOLDOWN = 5.minutes
  MANUAL_COOLDOWN_KEY = "localfolio:manual_market_price_refresh:last_started_at"

  def create
    return head :too_many_requests unless manual_refresh_available?

    Rails.cache.write(MANUAL_COOLDOWN_KEY, Time.current)
    instruments = traded_instruments.to_a
    RefreshStatus::Tracker.enqueue(scope: REFRESH_SCOPE, total_count: instruments.size)
    instruments.each do |instrument|
      result = refresh_enqueuer.enqueue(instrument:, refresh_scope: REFRESH_SCOPE)
      advance_manual_batch if result.nil? || result == RefreshCurrentMarketPriceJob::COALESCED
    end

    flash.now[:notice] = t("notices.Market price refresh started")

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash-messages", partial: "layouts/flash_messages"),
          turbo_stream.replace("refresh-status", partial: "refresh_status/status", locals: { status: RefreshStatus::Presenter.for, broadcast: true })
        ], status: :accepted
      end
      format.html do
        redirect_to positions_path, notice: flash[:notice]
      end
    end
  end

  private

  def refresh_enqueuer
    @refresh_enqueuer ||= MarketPrice::RefreshEnqueuer.new
  end

  def traded_instruments
    Instrument.where(
      id: Trade.where(user: User.owner).select(:instrument_id)
    )
  end

  def advance_manual_batch
    batch = RefreshStatus::State.read(REFRESH_SCOPE)
    RefreshStatus::Tracker.advance(batch) if batch&.active?
  end

  def manual_refresh_available?
    last_started_at = Rails.cache.read(MANUAL_COOLDOWN_KEY)
    last_started_at.nil? || Time.current - last_started_at >= MANUAL_COOLDOWN
  end
end
