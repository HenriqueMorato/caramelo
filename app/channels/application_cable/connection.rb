module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def self.disconnect_user(user)
      ActionCable.server.remote_connections.where(current_user: user).disconnect
    end

    def connect
      self.current_user = authenticated_user
      self.current_user ||= public_owner if public_single_access?
      reject_unauthorized_connection unless current_user
    end

    private

      def authenticated_user
        user = Session.find_by(id: cookies.signed[:session_id])&.user
        return unless user
        return unless user.password_configured?
        return user if Caramelo::AccountMode.multi? || user == User.owner_or_initialize

        nil
      end

      def public_single_access?
        Caramelo::AccountMode.single? &&
          Rails.application.config.x.caramelo.authentication_mode == "public"
      end

      def public_owner
        User.find_by(email_address: Rails.application.config.x.caramelo.owner_email)
      end
  end
end
