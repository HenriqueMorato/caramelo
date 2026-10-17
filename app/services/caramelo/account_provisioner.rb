module Caramelo
  class AccountProvisioner
    class NotReady < StandardError; end

    def self.call(email_address:, password:, password_confirmation:)
      new(email_address:, password:, password_confirmation:).call
    end

    def initialize(email_address:, password:, password_confirmation:)
      @email_address = email_address
      @password = password
      @password_confirmation = password_confirmation
    end

    def call
      ensure_multi_account_mode!
      ensure_owner_configured!

      # New accounts start empty. Startup refresh and trade callbacks prepare
      # replaceable market data after the account has durable source records.
      User.create!(
        email_address:,
        password:,
        password_confirmation:,
        password_configured_at: Time.current
      )
    end

    private

      attr_reader :email_address, :password, :password_confirmation

      def ensure_multi_account_mode!
        return if AccountMode.multi?

        raise NotReady, "Set CARAMELO_ACCOUNT_MODE=multi before creating another account."
      end

      def ensure_owner_configured!
        return if User.owner_or_initialize.password_configured?

        raise NotReady, "Set the configured owner's password with bin/caramelo-password setup first."
      end
  end
end
