class CurrentMarketPriceRefreshesController < ApplicationController
  allow_unauthenticated_access

  def create
    unless manual_refresh.call
      return respond_with_status_toast(
        t("market_data_health.show.Refresh throttled"),
        status: :too_many_requests,
        redirect_to: market_data_health_path
      )
    end

    flash.now[:notice] = t("notices.Market price refresh started")

    respond_to do |format|
      format.turbo_stream do
        status = RefreshStatus::Presenter.for
        render turbo_stream: [
          turbo_stream.replace("flash-messages", partial: "layouts/flash_messages"),
          turbo_stream.replace("refresh-status", partial: "refresh_status/status", locals: { status:, broadcast: true })
        ], status: :accepted
      end
      format.html do
        redirect_to positions_path, notice: flash[:notice]
      end
    end
  end

  private

  def manual_refresh
    @manual_refresh ||= MarketPrice::ManualRefresh.new
  end
end
