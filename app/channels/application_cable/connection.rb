module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = authenticated_user
      reject_unauthorized_connection unless current_user
    end

    private

      def authenticated_user
        user = Session.find_by(id: cookies.signed[:session_id])&.user
        return unless user
        return unless user.password_configured?
        return user if Caramelo::AccountMode.multi? || user == User.owner

        nil
      end
  end
end
