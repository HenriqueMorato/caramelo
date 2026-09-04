module PositionMaterializations
  class Rebuild
    def self.call(user: User.owner, instrument: nil)
      new(user:, instrument:).call
    end

    def initialize(user:, instrument: nil)
      @user = user
      @instrument = instrument
    end

    def call
      instruments.map do |record|
        materialization = PositionMaterialization.find_or_initialize_by(user:, instrument: record)
        materialization.save! unless materialization.persisted?
        PositionMaterializations::Refresh.call(materialization:)
      end
    end

    private

    attr_reader :user, :instrument

    def instruments
      return [ instrument ] if instrument

      user.trades.distinct.includes(:instrument).map(&:instrument)
    end
  end
end
