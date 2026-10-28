class PortfolioAllocationGroup < ApplicationRecord
  belongs_to :portfolio_allocation_plan, inverse_of: :allocation_groups
  belongs_to :asset_type, foreign_key: :asset_type_key, primary_key: :key,
    inverse_of: :portfolio_allocation_groups
  has_many :members, class_name: "PortfolioAllocationGroupMember", dependent: :delete_all,
    inverse_of: :portfolio_allocation_group

  normalizes :name, with: ->(value) { value.to_s.strip.squish }
  normalizes :asset_type_key, with: ->(value) { value.to_s.strip.downcase }
  before_validation :sync_normalized_name

  validates :name, presence: true, length: { maximum: 80 },
    uniqueness: { scope: :portfolio_allocation_plan_id, case_sensitive: false }
  validates :asset_type_key, presence: true
  validates :target_percentage, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validate :members_are_meaningful

  private

  def members_are_meaningful
    return if members.empty?

    errors.add(:members, "must include at least two instruments") if members.length < 2
    errors.add(:members, "must include at least one Buy instrument") unless members.any?(&:buy?)
  end

  def sync_normalized_name
    self.normalized_name = name.to_s.downcase
  end
end
