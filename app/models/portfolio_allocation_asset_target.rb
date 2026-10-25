class PortfolioAllocationAssetTarget < ApplicationRecord
  belongs_to :portfolio_allocation_plan, inverse_of: :asset_targets
  belongs_to :asset_type, foreign_key: :asset_type_key, primary_key: :key,
    inverse_of: :portfolio_allocation_asset_targets

  validates :asset_type_key, presence: true
  validates :target_percentage, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
end
