require "csv"

module TradeExport
  class Csv
    HEADERS = %w[
      trade_id traded_on side instrument_id ticker exchange instrument_name
      instrument_currency institution_id institution_name quantity unit_price
      fees_subunits fees_currency settlement_currency settlement_exchange_rate
      notes created_at updated_at
    ].freeze

    def self.call(user: User.owner)
      new(user:).call
    end

    def initialize(user:)
      @user = user
    end

    def call
      ::CSV.generate(headers: HEADERS, write_headers: true, row_sep: "\r\n") do |csv|
        trades.each { |trade| csv << row_for(trade) }
      end
    end

    private

    attr_reader :user

    def trades
      user.trades.includes(:instrument, :institution).order(:traded_on, :id)
    end

    def row_for(trade)
      [
        trade.id,
        trade.traded_on.iso8601,
        trade.side,
        trade.instrument_id,
        safe_text(trade.instrument.ticker),
        safe_text(trade.instrument.exchange),
        safe_text(trade.instrument.name),
        trade.currency,
        trade.institution_id,
        safe_text(trade.institution&.name),
        decimal(trade.quantity),
        decimal(trade.unit_price),
        trade.fees_cents,
        trade.currency,
        trade.settlement_currency,
        decimal(trade.settlement_exchange_rate),
        safe_text(trade.notes),
        trade.created_at.iso8601(6),
        trade.updated_at.iso8601(6)
      ]
    end

    def decimal(value)
      value&.to_d&.to_s("F")
    end

    def safe_text(value)
      return value unless value&.match?(/\A[=+\-@\t\r]/)

      "'#{value}"
    end
  end
end
