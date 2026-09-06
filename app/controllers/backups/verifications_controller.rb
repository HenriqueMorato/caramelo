module Backups
  class VerificationsController < ApplicationController
    allow_unauthenticated_access

    def create
      directory = Backup::Locator.resolve(params.expect(:identifier))
      Backup::Verifier.call(directory:)
      respond_with_toast(t("backups.verification.ready"), redirect_to: market_data_health_path(anchor: "backups"))
    rescue Backup::Error => error
      Rails.error.report(error, handled: true)
      respond_with_toast(t("backups.verification.failed"), alert: true, redirect_to: market_data_health_path(anchor: "backups"))
    end
  end
end
