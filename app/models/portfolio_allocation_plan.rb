class PortfolioAllocationPlan < ApplicationRecord
  belongs_to :user
  has_many :asset_targets, class_name: "PortfolioAllocationAssetTarget", dependent: :delete_all,
    inverse_of: :portfolio_allocation_plan
  has_many :instrument_targets, class_name: "PortfolioAllocationInstrumentTarget", dependent: :delete_all,
    inverse_of: :portfolio_allocation_plan

  validates :user, uniqueness: true

  def self.for(user:)
    find_or_create_by!(user:)
  end

  def configured?
    asset_targets.exists?
  end
end
