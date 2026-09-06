module Backups
  class CreationsController < ApplicationController
    allow_unauthenticated_access

    def create
      result = Backup::CreationRequest.call
      respond_with_toast(t("backups.creation.#{result}"), redirect_to: market_data_health_path(anchor: "backups"))
    rescue Backup::Error => error
      Rails.error.report(error, handled: true)
      respond_with_toast(t("backups.creation.failed"), alert: true, redirect_to: market_data_health_path(anchor: "backups"))
    end
  end
end
