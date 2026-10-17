module Caramelo
  module Environment
    DEFAULT_OWNER_EMAIL = "admin@caramelo.local"
    ACCOUNT_MODES = %w[single multi].freeze
    DEFAULT_ACCOUNT_MODE = "single"
    AUTHENTICATION_MODES = %w[public password].freeze
    DEFAULT_AUTHENTICATION_MODE = "public"
    DEFAULT_PASSWORD_MIN_LENGTH = 8
    DEFAULT_PASSWORD_REQUIRE_UPPERCASE = true
    DEFAULT_PASSWORD_REQUIRE_LOWERCASE = true
    DEFAULT_PASSWORD_REQUIRE_NUMBER = true
    DEFAULT_PASSWORD_REQUIRE_SYMBOL = true
    PASSWORD_MAX_LENGTH = 72

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

    def self.password_policy
      minimum_length = integer_setting("PASSWORD_MIN_LENGTH", default: DEFAULT_PASSWORD_MIN_LENGTH)
      unless minimum_length.between?(1, PASSWORD_MAX_LENGTH)
        raise ArgumentError,
          "CARAMELO_PASSWORD_MIN_LENGTH must be between 1 and #{PASSWORD_MAX_LENGTH}"
      end

      {
        minimum_length: minimum_length,
        require_uppercase: boolean_setting("PASSWORD_REQUIRE_UPPERCASE", default: DEFAULT_PASSWORD_REQUIRE_UPPERCASE),
        require_lowercase: boolean_setting("PASSWORD_REQUIRE_LOWERCASE", default: DEFAULT_PASSWORD_REQUIRE_LOWERCASE),
        require_number: boolean_setting("PASSWORD_REQUIRE_NUMBER", default: DEFAULT_PASSWORD_REQUIRE_NUMBER),
        require_symbol: boolean_setting("PASSWORD_REQUIRE_SYMBOL", default: DEFAULT_PASSWORD_REQUIRE_SYMBOL)
      }.freeze
    end

    def self.integer_setting(name, default:)
      Integer(fetch(name, default: default).to_s, 10)
    rescue ArgumentError, TypeError
      raise ArgumentError, "CARAMELO_#{name} must be a whole number"
    end
    private_class_method :integer_setting

    def self.boolean_setting(name, default:)
      value = fetch(name, default: default).to_s.strip.downcase
      return true if value == "true"
      return false if value == "false"

      raise ArgumentError, "CARAMELO_#{name} must be one of: true, false"
    end
    private_class_method :boolean_setting
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
