module Trades
  class HistoricalDataBackfillEnqueuer
    def self.call(trade:)
      new(trade:).call
    end

    def initialize(trade:)
      @trade = trade
    end

    def call
      targets.each do |instrument_id, currency, from_date|
        instrument = Instrument.find_by(id: instrument_id)
        next unless instrument

        HistoricalDataBackfill.enqueue_for(instrument:, currency:, from_date:)
      end
      enqueue_reporting_currency_preparation
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { trade_id: trade.id })
    end

    private

    attr_reader :trade

    def targets
      current_target = [ trade.instrument_id, trade.currency, trade.traded_on ]
      changed_history_input = %w[instrument_id currency traded_on].any? { |attribute| trade.previous_changes.key?(attribute) }
      return [ current_target ] unless changed_history_input

      previous_target = [
        trade.previous_changes.fetch("instrument_id", [ trade.instrument_id ]).first,
        trade.previous_changes.fetch("currency", [ trade.currency ]).first,
        trade.previous_changes.fetch("traded_on", [ trade.traded_on ]).first
      ]
      [ previous_target, current_target ].uniq
    end

    def enqueue_reporting_currency_preparation
      return unless trade.saved_change_to_settlement_currency? || trade.saved_change_to_settlement_exchange_rate?
      return if trade.settlement_currency.blank? || trade.settlement_currency == trade.user.reporting_currency

      PrepareReportingCurrencyJob.enqueue_for(user: trade.user)
    end
  end
end
