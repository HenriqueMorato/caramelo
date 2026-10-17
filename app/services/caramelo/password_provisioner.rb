module Caramelo
  class PasswordProvisioner
    class NotReady < StandardError; end
    class InvalidCurrentPassword < StandardError; end

    def self.setup_owner(password:, password_confirmation:)
      owner = User.owner_or_initialize
      if User.owner_configuration_conflict?
        raise NotReady, "Configured owner email does not match an existing account. Restore CARAMELO_OWNER_EMAIL before setup."
      end

      provision(owner, password:, password_confirmation:, require_unconfigured: true)
    end

    def self.change(user:, current_password:, password:, password_confirmation:)
      user.with_lock do
        raise NotReady, "This account does not have a configured password." unless user.password_configured?
        raise InvalidCurrentPassword, "The current password is incorrect." unless user.authenticate(current_password)

        provision_locked(user, password:, password_confirmation:)
      end

      disconnect_user(user)
      user
    end

    def self.reset(user:, password:, password_confirmation:)
      user.with_lock do
        raise NotReady, "This account does not have a configured password." unless user.password_configured?

        provision_locked(user, password:, password_confirmation:)
      end

      disconnect_user(user)
      user
    end

    def self.provision(user, password:, password_confirmation:, require_unconfigured: false)
      if user.persisted?
        user.with_lock do
          if require_unconfigured && user.password_configured?
            raise NotReady, "The configured owner already has a password."
          end

          provision_locked(user, password:, password_confirmation:)
        end
      else
        user.transaction do
          provision_locked(user, password:, password_confirmation:)
        end
      end

      disconnect_user(user)
      user
    rescue ActiveRecord::RecordNotUnique
      raise NotReady, "The configured owner was created by another process. Try again."
    end

    private_class_method :provision

    def self.provision_locked(user, password:, password_confirmation:)
      user.assign_attributes(password:, password_confirmation:, password_configured_at: Time.current)
      user.save!
      user.sessions.destroy_all
    end
    private_class_method :provision_locked

    def self.disconnect_user(user)
      ApplicationCable::Connection.disconnect_user(user)
    rescue StandardError => error
      Rails.logger.warn("Could not disconnect Action Cable sessions for user #{user.id}: " \
        "#{error.class}: #{error.message}")
    end
    private_class_method :disconnect_user
  end
end
