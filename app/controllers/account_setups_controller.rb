class AccountSetupsController < ApplicationController
  allow_unauthenticated_access
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_account_setup_path, alert: I18n.t("alerts.Try again later") }
  before_action :ensure_password_setup_required

  def new
    @owner = User.owner_or_initialize
  end

  def create
    outcome = with_setup_lock do
      @owner = User.owner_or_initialize
      @owner.persisted? ? @owner.with_lock { save_password } : save_password
    end

    return redirect_to new_session_path if outcome == :already_configured
    return render(:new, status: :unprocessable_content) unless outcome

    prepare_account_data
    start_new_session_for(@owner)
    redirect_to after_authentication_url, notice: t("account_setup.Password saved")
  end

  private

  def account_setup_params
    params.expect(user: [ :password, :password_confirmation ])
  end

  def ensure_password_setup_required
    return redirect_to root_path unless authentication_required?
    redirect_to new_session_path unless account_setup_required?
  end

  def save_password
    return :already_configured if @owner.password_configured?

    @owner.assign_attributes(account_setup_params)
    @owner.password_configured_at = Time.current
    @owner.errors.add(:password, :blank) if @owner.password.blank?
    @owner.errors.empty? && @owner.save
  end

  def with_setup_lock
    # A fresh database has no owner row to lock, so serialize the first claim across web processes.
    File.open(Rails.root.join("tmp/caramelo-account-setup.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  def prepare_account_data
    PrepareReportingCurrencyJob.enqueue_for(user: @owner)
    InstrumentPerformance::StartupPreparation.call(user: @owner)
    CorporateActionImports::Automation.call(user: @owner)
  end
end
