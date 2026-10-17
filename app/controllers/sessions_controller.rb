class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: I18n.t("alerts.Try again later") }

  def new
  end

  def create
    if authenticate_and_start_session
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: t("alerts.Invalid credentials")
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end

  private

  def authenticate_and_start_session
    credentials = params.permit(:email_address, :password)
    user = User.authenticate_by(credentials)
    return false unless user

    user.with_lock do
      next false unless login_allowed?(user, credentials[:password])

      start_new_session_for(user)
      true
    end
  end

  def login_allowed?(user, password)
    user.password_configured? && user.authenticate(password) &&
      (Caramelo::AccountMode.multi? || user == User.owner_or_initialize)
  end
end
