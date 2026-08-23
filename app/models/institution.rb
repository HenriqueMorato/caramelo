class Institution < ApplicationRecord
  belongs_to :user

  normalizes :name, with: ->(name) { name.strip.squish }

  validates :name, presence: true, uniqueness: { scope: :user_id, case_sensitive: false }

  scope :active, -> { where(active: true) }
  scope :alphabetical, -> { order(:name) }
end
