module InstrumentPerformance
  class StartupPreparation
    def self.call(user: User.owner)
      new(user:).call
    end

    def initialize(user:)
      @user = user
    end

    def call
      traded_instruments.each do |instrument, first_trade|
        [ instrument.currency, user.reporting_currency ].uniq.each do |reporting_currency|
          Performance::SeriesRefresh.enqueue(
            user:, instrument:, reporting_currency:, from: first_trade, to: Date.current
          )
        end
      end
    end

    private

    attr_reader :user

    def traded_instruments
      starts = user.trades.where(traded_on: ..Date.current).group(:instrument_id).minimum(:traded_on)
      Instrument.where(id: starts.keys).index_with { |instrument| starts.fetch(instrument.id) }
    end
  end
end
