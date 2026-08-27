class CurrentMarketPriceRefreshesController < ApplicationController
  allow_unauthenticated_access

  def create
    traded_instruments.each do |instrument|
      refresh_enqueuer.enqueue(instrument:)
    end

    respond_to do |format|
      format.turbo_stream { head :accepted }
      format.html do
        redirect_to positions_path, notice: t("notices.Market price refresh started")
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
end
