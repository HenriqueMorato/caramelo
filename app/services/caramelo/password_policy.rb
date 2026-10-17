module Caramelo
  class PasswordPolicy
    REQUIREMENTS = {
      require_uppercase: [ /[[:upper:]]/, :must_include_uppercase ],
      require_lowercase: [ /[[:lower:]]/, :must_include_lowercase ],
      require_number: [ /[[:digit:]]/, :must_include_number ],
      require_symbol: [ /[^\p{Alnum}\s]/, :must_include_symbol ]
    }.freeze

    def self.validate(password, errors:)
      policy = current
      errors.add(:password, :too_short, count: policy.fetch(:minimum_length)) if password.length < policy.fetch(:minimum_length)

      REQUIREMENTS.each do |requirement, (pattern, error)|
        errors.add(:password, error) if policy.fetch(requirement) && !password.match?(pattern)
      end
    end

    def self.current
      Rails.application.config.x.caramelo.password_policy
    end

    def self.minimum_length
      current.fetch(:minimum_length)
    end
  end
end
