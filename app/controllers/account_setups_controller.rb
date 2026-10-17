class AccountSetupsController < ApplicationController
  allow_unauthenticated_access
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_account_setup_path, alert: I18n.t("alerts.Try again later") }
  before_action :ensure_password_setup_required

  def new
    @owner = User.owner_or_initialize
  end

  def create
    @owner = User.owner_or_initialize
    @owner.assign_attributes(account_setup_params)
    @owner.password_configured_at = Time.current

    if @owner.password.blank?
      @owner.errors.add(:password, :blank)
    end

    if @owner.errors.empty? && @owner.save
      prepare_account_data
      start_new_session_for(@owner)
      redirect_to after_authentication_url, notice: t("account_setup.Password saved")
    else
      render :new, status: :unprocessable_content
    end
  end

  private

  def account_setup_params
    params.expect(user: [ :password, :password_confirmation ])
  end

  def ensure_password_setup_required
    redirect_to new_session_path if User.owner_or_initialize.password_configured?
  end

  def prepare_account_data
    PrepareReportingCurrencyJob.enqueue_for(user: @owner)
    InstrumentPerformance::StartupPreparation.call(user: @owner)
    CorporateActionImports::Automation.call(user: @owner)
  end
end
