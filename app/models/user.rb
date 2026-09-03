class User < ApplicationRecord
  has_many :portfolio_performance_observations, dependent: :delete_all
  has_many :portfolio_performance_materializations, dependent: :delete_all
  has_secure_password
  has_many :institutions, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :trades, dependent: :restrict_with_error

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  def self.owner
    find_by!(email_address: Rails.application.config.x.local_folio.owner_email)
  end
end
