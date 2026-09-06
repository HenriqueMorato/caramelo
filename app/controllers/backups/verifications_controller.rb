module Backups
  class VerificationsController < ApplicationController
    allow_unauthenticated_access

    def create
      directory = Backup::Locator.resolve(params.expect(:identifier))
      Backup::Verifier.call(directory:)
      redirect_to market_data_health_path(anchor: "backups"), notice: t("backups.verification.ready")
    rescue Backup::Error => error
      Rails.error.report(error, handled: true)
      redirect_to market_data_health_path(anchor: "backups"), alert: t("backups.verification.failed")
    end
  end
end
