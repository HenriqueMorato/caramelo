module PositionMaterializations
  class Refresh
    def self.call(materialization:)
      new(materialization:).call
    end

    def initialize(materialization:)
      @materialization = materialization
    end

    def call
      generation = mark_refreshing
      source_trades = trades
      position = Position.for(instrument: materialization.instrument, trades: source_trades)
      publish(position, source_trades, generation)
      materialization
    rescue Position::InvalidLongOnlyData => error
      mark_failed(error, generation)
      materialization
    end

    private

    attr_reader :materialization

    def mark_refreshing
      materialization.with_lock do
        materialization.update!(status: "refreshing", error_class: nil, error_message: nil)
        materialization.source_generation
      end
    end

    def trades
      materialization.user.trades.where(instrument: materialization.instrument).order(:traded_on, :id).to_a
    end

    def publish(position, source_trades, generation)
      materialization.with_lock do
        return unless materialization.source_generation == generation

        materialization.update!(attributes_for(position, source_trades).merge(calculated_generation: generation))
      end
    end

    def mark_failed(error, generation)
      materialization.with_lock do
        return unless materialization.source_generation == generation

        materialization.update!(status: "failed", error_class: error.class.name, error_message: error.message)
      end
    end

    def attributes_for(position, source_trades)
      {
        status: "complete",
        quantity: position.quantity,
        cost_basis_amount: position.analytical_cost_basis_amount,
        average_unit_cost: position.average_unit_cost,
        realized_gain_amount: position.analytical_realized_gain_amount,
        source_trade_id: source_trades.last&.id,
        source_trade_updated_at: source_trades.last&.updated_at,
        calculated_at: Time.current
      }
    end
  end
end
