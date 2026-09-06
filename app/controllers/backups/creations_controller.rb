module Backups
  class CreationsController < ApplicationController
    allow_unauthenticated_access

    def create
      result = Backup::CreationRequest.call
      redirect_to market_data_health_path(anchor: "backups"), notice: t("backups.creation.#{result}")
    rescue Backup::Error => error
      Rails.error.report(error, handled: true)
      redirect_to market_data_health_path(anchor: "backups"), alert: t("backups.creation.failed")
    end
  end
end
