class User < ApplicationRecord
  has_secure_password
  has_many :institutions, dependent: :destroy
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  def self.owner
    find_by!(email_address: Rails.application.config.x.local_folio.owner_email)
  end
end
