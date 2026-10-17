module Caramelo
  module Environment
    DEFAULT_OWNER_EMAIL = "admin@caramelo.local"
    ACCOUNT_MODES = %w[single multi].freeze
    DEFAULT_ACCOUNT_MODE = "single"
    AUTHENTICATION_MODES = %w[public password].freeze
    DEFAULT_AUTHENTICATION_MODE = "public"

    def self.fetch(name, default:)
      ENV.fetch("CARAMELO_#{name}", default)
    end

    def self.account_mode
      mode = fetch("ACCOUNT_MODE", default: DEFAULT_ACCOUNT_MODE).to_s.strip.downcase
      mode = DEFAULT_ACCOUNT_MODE if mode.empty?
      return mode if ACCOUNT_MODES.include?(mode)

      raise ArgumentError, "CARAMELO_ACCOUNT_MODE must be one of: #{ACCOUNT_MODES.join(', ')}"
    end

    def self.authentication_mode
      mode = fetch("AUTHENTICATION_MODE", default: DEFAULT_AUTHENTICATION_MODE).to_s.strip.downcase
      mode = DEFAULT_AUTHENTICATION_MODE if mode.empty?
      return mode if AUTHENTICATION_MODES.include?(mode)

      raise ArgumentError,
        "CARAMELO_AUTHENTICATION_MODE must be one of: #{AUTHENTICATION_MODES.join(', ')}"
    end
  end

  module AccountMode
    def self.current
      Rails.application.config.x.caramelo.account_mode
    end

    def self.single?
      current == "single"
    end

    def self.multi?
      current == "multi"
    end
  end
end
