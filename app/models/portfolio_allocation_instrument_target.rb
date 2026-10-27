class PortfolioAllocationInstrumentTarget < ApplicationRecord
  belongs_to :portfolio_allocation_plan, inverse_of: :instrument_targets
  belongs_to :instrument
  belongs_to :asset_type, foreign_key: :asset_type_key, primary_key: :key,
    inverse_of: :portfolio_allocation_instrument_targets

  validates :asset_type_key, presence: true
  validates :instrument_id, uniqueness: { scope: :portfolio_allocation_plan_id }
  validates :target_percentage, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validate :instrument_asset_type_matches

  private

  def instrument_asset_type_matches
    return if instrument.blank? || asset_type_key.blank? || instrument.asset_type == asset_type_key

    errors.add(:asset_type_key, :inclusion)
  end
end
