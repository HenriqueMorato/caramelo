class PortfolioAllocationGroupMember < ApplicationRecord
  enum :purchase_policy, { buy: "buy", hold: "hold" }

  belongs_to :portfolio_allocation_group, inverse_of: :members
  belongs_to :instrument, inverse_of: :portfolio_allocation_group_members

  validates :instrument_id, uniqueness: { scope: :portfolio_allocation_group_id }
  validates :purchase_policy, presence: true
  validate :instrument_asset_type_matches

  private

  def instrument_asset_type_matches
    return if instrument.blank? || portfolio_allocation_group.blank?
    return if instrument.asset_type == portfolio_allocation_group.asset_type_key

    errors.add(:instrument, "must use the group's asset type")
  end
end
