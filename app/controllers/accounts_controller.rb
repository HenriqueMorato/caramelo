class AccountsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_account_path, alert: I18n.t("alerts.Try again later") }
  before_action :ensure_multi_account_mode
  before_action :redirect_to_initial_setup, only: %i[ new create ]

  def new
    @user = User.new
  end

  def create
    @user = User.new(account_params)
    @user.password_configured_at = Time.current

    if @user.save
      prepare_account_data
      start_new_session_for(@user)
      redirect_to after_authentication_url, notice: t("accounts.Account created")
    else
      render :new, status: :unprocessable_content
    end
  end

  private

  def account_params
    params.expect(user: %i[email_address password password_confirmation])
  end

  def ensure_multi_account_mode
    return if Caramelo::AccountMode.multi?

    redirect_to new_session_path
  end

  def redirect_to_initial_setup
    return if User.where.not(password_configured_at: nil).exists?

    redirect_to new_account_setup_path
  end

  def prepare_account_data
    PrepareReportingCurrencyJob.enqueue_for(user: @user)
    InstrumentPerformance::StartupPreparation.call(user: @user)
    CorporateActionImports::Automation.call(user: @user)
  end
end
