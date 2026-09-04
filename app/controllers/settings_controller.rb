class SettingsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_owner

  def show
  end

  def update
    unless @owner.update(params.expect(user: [ :reporting_currency ]))
      render :show, status: :unprocessable_content
      return
    end

    if PrepareReportingCurrencyJob.enqueue_for(user: @owner)
      redirect_to settings_path, notice: t("settings.Saved"), status: :see_other
    else
      redirect_to settings_path, alert: t("settings.Preparation failed"), status: :see_other
    end
  end

  private

  def set_owner
    @owner = User.owner
  end
end
