module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = authenticated_user || User.owner
    end

    private

      def authenticated_user
        Session.find_by(id: cookies.signed[:session_id])&.user
      end
  end
end
