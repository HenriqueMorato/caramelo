class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path, alert: I18n.t("alerts.Try again later") }

  def new
  end

  def create
    if user = User.find_by(email_address: params[:email_address].to_s.strip.downcase)
      PasswordsMailer.reset(user).deliver_later
    end

    redirect_to new_session_path, notice: t("notices.Password reset instructions sent")
  end

  def edit
  end

  def update
    attributes = params.permit(:password, :password_confirmation)
    if attributes[:password].blank?
      redirect_to edit_password_path(params[:token]), alert: t("alerts.Password required")
    elsif @user.update(attributes)
      @user.update_column(:password_configured_at, Time.current)
      @user.sessions.destroy_all
      redirect_to new_session_path, notice: t("notices.Password was reset")
    else
      redirect_to edit_password_path(params[:token]), alert: t("alerts.Passwords did not match")
    end
  end

  private
    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path, alert: t("alerts.Password reset link expired")
    end
end
