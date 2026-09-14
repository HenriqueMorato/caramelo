class Institution < ApplicationRecord
  extend FriendlyId

  friendly_id :slug_candidates, use: :slugged

  belongs_to :user
  has_many :trades, dependent: :restrict_with_error

  normalizes :name, with: ->(name) { name.strip.squish }

  validates :name, presence: true, uniqueness: { scope: :user_id, case_sensitive: false }

  scope :active, -> { where(active: true) }
  scope :alphabetical, -> { order(:name) }

  private

  def slug_candidates
    [ :name, [ :name, :user_id ] ]
  end
end
