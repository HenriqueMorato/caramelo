class User < ApplicationRecord
  has_many :portfolio_performance_observations, dependent: :delete_all
  has_many :portfolio_performance_materializations, dependent: :delete_all
  has_many :position_materializations, dependent: :delete_all
  has_secure_password
  has_many :institutions, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :trades, dependent: :restrict_with_error

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :reporting_currency, with: ->(currency) { currency.strip.upcase }

  validates :reporting_currency, presence: true
  validates :reporting_currency, inclusion: { in: ReportingCurrency::SUPPORTED_CODES, message: :invalid }

  def self.owner
    find_by!(email_address: Rails.application.config.x.local_folio.owner_email)
  end
end
