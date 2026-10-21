module MarketData
  class RecoveriesController < ApplicationController
    def create
      target = TargetResolver.call(attributes: target_params, owner: current_account)
      result = Recovery.call(target:, range: recovery_range, owner: current_account)

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
        respond_with_started("Market data recovery started.", target: result.target)
      end
    rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ArgumentError
      respond_with_status_toast("This data target is no longer available.",
        status: :unprocessable_entity, redirect_to: market_data_health_path)
    end

    def destroy
      target = TargetResolver.call(attributes: target_params, owner: current_account)
      raise ArgumentError, "reset preview is required" if params[:preview_token].blank?

      result = Reset.call(target:, preview_token: params[:preview_token], owner: current_account)

      if result.queued?
        respond_with_started("Data replacement started.", target: result.target)
      elsif result.busy?
        respond_with_status_toast("A refresh for this data target is already running.",
          status: :conflict, redirect_to: market_data_health_path)
      else
        respond_with_status_toast("This data target cannot be replaced.",
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

    def respond_with_started(message, target:)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.remove(target.dom_id),
            turbo_stream.update(
              "toast-feedback",
              partial: "layouts/toast",
              locals: { message:, alert: false }
            )
          ]
        end
        format.html do
          redirect_to market_data_health_path, flash: { notice: message }
        end
      end
    end
  end
end
