module Performance
  class ObservationInvalidator
    def self.mark!(user:, from:)
      currencies = user.portfolio_performance_materializations.pluck(:reporting_currency)
      currencies |= [ user.reporting_currency ]
      currencies.sort.each { |reporting_currency| new(user:, from:, reporting_currency:).mark! }
    end

    def self.enqueue(user:, from:)
      new(user:, from:).enqueue
    end

    def self.mark_instrument!(user:, instrument:, from:, reporting_currency: nil)
      instrument_currencies(user:, instrument:, reporting_currency:).sort.each do |currency|
        new(user:, instrument:, from:, reporting_currency: currency).mark!
      end
    end

    def self.enqueue_instrument(user:, instrument:, from:, reporting_currency: nil)
      instrument_currencies(user:, instrument:, reporting_currency:).sort.each do |currency|
        new(user:, instrument:, from:, reporting_currency: currency).enqueue
      end
    end

    def self.instrument_currencies(user:, instrument:, reporting_currency:)
      return [ CurrencyCode.normalize(reporting_currency) ] if reporting_currency

      currencies = user.instrument_performance_materializations.where(instrument:).pluck(:reporting_currency)
      currencies | [ instrument.currency, user.reporting_currency ]
    end
    private_class_method :instrument_currencies

    def initialize(user:, from:, instrument: nil, reporting_currency: user.reporting_currency,
      store: nil, refresher: SeriesRefresh, materialization: nil)
      @user = user
      @from = from
      @instrument = instrument
      @store = store || default_store(reporting_currency:)
      @refresher = refresher
      @materialization = materialization || default_materialization(reporting_currency:)
    end

    def mark!
      return :future unless from <= Date.current

      materialization.request!(from:, to: Date.current, source_changed: true)
      return clear_observations unless target_has_trades?

      store.stale_from(from)
      :stale
    end

    def enqueue
      return :future unless from <= Date.current

      attributes = { user:, from:, to: Date.current, reporting_currency: materialization.reporting_currency }
      attributes[:instrument] = instrument if instrument
      refresher.enqueue(**attributes)
    rescue StandardError => error
      Rails.error.report(
        error, handled: true, context: { user_id: user.id, instrument_id: instrument&.id, from: }
      )
      :failed
    end

    private

    attr_reader :user, :instrument, :from, :store, :refresher, :materialization

    def default_store(reporting_currency:)
      if instrument
        InstrumentPerformance::ObservationStore.new(user:, instrument:, reporting_currency:)
      else
        ObservationStore.new(user:, reporting_currency:)
      end
    end

    def default_materialization(reporting_currency:)
      if instrument
        InstrumentPerformanceMaterialization.for(user:, instrument:, reporting_currency:)
      else
        PortfolioPerformanceMaterialization.for(user:, reporting_currency:)
      end
    end

    def target_has_trades?
      instrument ? user.trades.exists?(instrument:) : user.trades.exists?
    end

    def clear_observations
      store.delete_all
      :cleared
    end
  end
end
