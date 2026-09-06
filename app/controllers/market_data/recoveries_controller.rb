module MarketData
  class RecoveriesController < ApplicationController
    allow_unauthenticated_access

    def create
      target = TargetResolver.call(attributes: target_params)
      result = Recovery.call(target:, range: recovery_range)

      if result.throttled?
        respond_with_status_toast("This data target was refreshed recently. Try again shortly.",
          status: :too_many_requests, redirect_to: market_data_health_path)
      elsif result.unsupported?
        respond_with_status_toast("This data target cannot be refreshed yet.",
          status: :unprocessable_entity, redirect_to: market_data_health_path)
      elsif result.already_running?
        respond_with_status_toast("A refresh for this data target is already running.",
          status: :conflict, redirect_to: market_data_health_path)
      else
        respond_with_toast("Market data recovery started.", redirect_to: market_data_health_path)
      end
    rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ArgumentError
      respond_with_status_toast("This data target is no longer available.",
        status: :unprocessable_entity, redirect_to: market_data_health_path)
    end

    def destroy
      target = TargetResolver.call(attributes: target_params)
      raise ArgumentError, "reset preview is required" if params[:preview_token].blank?

      result = Reset.call(target:, preview_token: params[:preview_token])

      if result.queued?
        respond_with_toast("Quote refresh started.", redirect_to: market_data_health_path)
      elsif result.busy?
        respond_with_status_toast("A refresh for this quote is already running.",
          status: :conflict, redirect_to: market_data_health_path)
      else
        respond_with_status_toast("This quote cannot be reset.",
          status: :unprocessable_entity, redirect_to: market_data_health_path)
      end
    rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ArgumentError
      respond_with_status_toast("This data target is no longer available.",
        status: :unprocessable_entity, redirect_to: market_data_health_path)
    end

    private

    def target_params
      params.require(:target).permit(
        :kind, :record_id, :base_currency, :quote_currency, :provider
      )
    end

    def recovery_range
      return unless params[:from].present? || params[:to].present?

      from = Date.iso8601(params.require(:from))
      to = Date.iso8601(params.require(:to))
      raise ArgumentError, "recovery range must be chronological and in the past" unless from <= to && to <= Date.current

      from..to
    end
  end
end
