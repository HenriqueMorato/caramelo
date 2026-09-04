class PositionMaterialization < ApplicationRecord
  belongs_to :user
  belongs_to :instrument

  enum :status, { pending: "pending", refreshing: "refreshing", complete: "complete", failed: "failed" }

  validates :source_generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :quantity, :cost_basis_amount, :average_unit_cost, :realized_gain_amount,
    numericality: true

  def stale?
    !complete? || (calculated_generation || 0) != source_generation
  end

  def latest_trade_id
    user.trades.where(instrument:).maximum(:id)
  end

  def latest_trade_updated_at
    user.trades.where(instrument:).maximum(:updated_at)
  end

  def queue_refresh!
    with_lock do
      update!(status: "pending", source_generation: source_generation + 1,
        error_class: nil, error_message: nil)
    end
  end
end
