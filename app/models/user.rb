class User < ApplicationRecord
  has_many :instrument_performance_observations, dependent: :delete_all
  has_many :instrument_performance_materializations, dependent: :delete_all
  has_many :portfolio_performance_observations, dependent: :delete_all
  has_many :portfolio_performance_materializations, dependent: :delete_all
  has_many :position_materializations, dependent: :delete_all
  has_many :corporate_actions, dependent: :restrict_with_error
  has_many :corporate_action_imports, dependent: :delete_all
  has_many :corporate_action_import_scans, dependent: :delete_all
  has_secure_password
  has_many :institutions, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :trades, dependent: :restrict_with_error

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :reporting_currency, with: ->(currency) { currency.strip.upcase }

  validates :email_address, presence: true, length: { maximum: 320 },
    uniqueness: { case_sensitive: false }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :reporting_currency, presence: true
  validates :reporting_currency, inclusion: { in: ReportingCurrency::SUPPORTED_CODES, message: :invalid }
  validate :password_meets_policy, if: -> { password_configured_at.present? }

  def password_configured?
    password_configured_at.present?
  end

  def self.owner
    owner = owner_or_initialize
    return owner if owner.persisted?

    raise ActiveRecord::RecordNotFound, "configured owner does not exist"
  end

  def self.owner_or_initialize
    configured_email = Rails.application.config.x.caramelo.owner_email
    find_or_initialize_by(email_address: configured_email)
  end

  # Legacy single-account entry points may omit their account argument. Never
  # resolve that omission to the configured owner once account isolation is on.
  def self.default_owner
    raise ArgumentError, "owner must be provided in multi-account mode" if Caramelo::AccountMode.multi?

    owner
  end

  def self.owner_configuration_conflict?
    owner_or_initialize.new_record? && exists?
  end

  private

    def password_meets_policy
      if password.nil? && password_digest.present?
        return
      end

      if password.blank?
        errors.add(:password, :blank)
        return
      end

      Caramelo::PasswordPolicy.validate(password, errors: errors)
    end
end
