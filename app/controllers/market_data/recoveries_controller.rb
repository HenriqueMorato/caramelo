module MarketData
  class RecoveriesController < ApplicationController
    allow_unauthenticated_access

    def create
      target = TargetResolver.call(attributes: target_params)
      result = Recovery.call(target:, range: recovery_range)

      if result.throttled?
        head :too_many_requests
      elsif result.unsupported?
        head :unprocessable_entity
      else
        redirect_to market_data_health_path, notice: "Market data recovery started."
      end
    rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ArgumentError
      head :unprocessable_entity
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
      from..to
    end
  end
end
