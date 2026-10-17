module Authentication
  extend ActiveSupport::Concern

  SESSION_CREATION_RETRIES = 2

  included do
    before_action :require_authentication
    helper_method :authenticated?, :current_user, :current_account
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def current_user
      resume_session&.user
    end

    def current_account
      if Caramelo::AccountMode.single?
        owner = User.owner_or_initialize
        return owner unless owner.persisted?

        return User.owner
      end

      current_user
    end

    def require_authentication
      return request_account_setup if account_setup_required?

      resume_session || request_authentication
    end

    def account_setup_required?
      return !User.owner_or_initialize.password_configured? if Caramelo::AccountMode.single?

      !User.where.not(password_configured_at: nil).exists?
    end

    def resume_session
      session = Current.session ||= find_session_by_cookie
      return unless session
      return session if session.user.password_configured? &&
        (Caramelo::AccountMode.multi? || session.user == User.owner)

      Current.session = nil
      cookies.delete(:session_id)
      nil
    end

    def find_session_by_cookie
      Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def request_account_setup
      redirect_to new_account_setup_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def start_new_session_for(user)
      session = create_session_with_retry(user)
      session.tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def create_session_with_retry(user)
      attempts = 0
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip)
    rescue ActiveRecord::StatementTimeout => error
      raise unless error.message.include?("database is locked") && attempts < SESSION_CREATION_RETRIES

      attempts += 1
      sleep(attempts * 0.1)
      retry
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
