module Instruments
  class CurrentMarketPriceRefreshesController < ApplicationController
    allow_unauthenticated_access

    def create
      instrument = Instrument.find(params.expect(:instrument_id))
      raise ActiveRecord::RecordNotFound unless refresh_enqueuer.enqueue(instrument:)

      respond_to do |format|
        format.turbo_stream { head :accepted }
        format.html do
          redirect_to instrument, notice: t("notices.Market price refresh started")
        end
      end
    end

    private

    def refresh_enqueuer
      @refresh_enqueuer ||= MarketPrice::RefreshEnqueuer.new
    end
  end
end
