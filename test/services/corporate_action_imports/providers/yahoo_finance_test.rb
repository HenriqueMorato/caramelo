require "test_helper"

class CorporateActionImports::Providers::YahooFinanceTest < ActiveSupport::TestCase
  test "registers Yahoo Finance through the provider registry" do
    assert_equal MarketData::YahooFinance::MARKET_CONFIGURATION.identifier,
      CorporateActionImports::Providers::YAHOO_FINANCE
    assert_equal [ CorporateActionImports::Providers::YAHOO_FINANCE ],
      CorporateActionImports::Providers::SUPPORTED_SOURCES
    assert_equal CorporateActionImports::Providers::YAHOO_FINANCE,
      CorporateActionImports::Providers::YahooFinance::IDENTIFIER
  end

  test "maps provider events to review candidates with exchange-aware identity" do
    event = MarketData::YahooFinance::HistoryClient::CorporateActionEvent.new(
      kind: :dividend, source_reference: "1787851200", event_on: Date.new(2026, 8, 27),
      amount: BigDecimal("0.123456789"), ratio_numerator: nil, ratio_denominator: nil,
      raw_payload: { "amount" => "0.123456789" }
    )
    provider = CorporateActionImports::Providers::YahooFinance.new(client: FakeClient.new([ event ]))

    candidate = provider.fetch(
      instrument: instruments(:voo_arcx), from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31)
    ).sole

    assert_equal "dividend", candidate.kind
    assert_predicate candidate, :dividend?
    assert_predicate candidate, :cash_action?
    assert_equal "VOO:dividend:1787851200", candidate.source_reference
    assert_equal "VOO", candidate.provider_symbol
    assert_equal "ARCX", candidate.provider_exchange
    assert_equal "USD", candidate.currency
    assert_equal "0.123456789", candidate.amount_per_share.to_s("F")
    assert_includes candidate.warnings, "payment_date_required"
  end

  test "does not ask Yahoo for unsupported exchanges" do
    client = FakeClient.new([])
    instrument = Instrument.new(ticker: "UNKNOWN", exchange: "XXXX", name: "Unknown", currency: "USD")

    assert_empty provider(client).fetch(instrument:, from: Date.current - 1.day, to: Date.current)
    assert_empty client.requests
  end

  test "maps an increasing split to the import split kind" do
    event = MarketData::YahooFinance::HistoryClient::CorporateActionEvent.new(
      kind: :split, source_reference: "1787851200", event_on: Date.new(2026, 8, 27),
      amount: nil, ratio_numerator: 2, ratio_denominator: 1,
      raw_payload: { "splitRatio" => "2:1" }
    )
    candidate = provider(FakeClient.new([ event ])).fetch(
      instrument: instruments(:petr4_bvmf), from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31)
    ).sole

    assert_equal "split", candidate.kind
    refute_predicate candidate, :cash_action?
    assert_equal [ 2, 1 ], [ candidate.ratio_numerator, candidate.ratio_denominator ]
    assert_equal "PETR4.SA:split:1787851200", candidate.source_reference
  end

  class FakeClient
    attr_reader :events, :requests

    def initialize(events)
      @events = events
      @requests = []
    end

    def corporate_action_events(identifier:, from:, to:)
      requests << [ identifier.value, from, to ]
      events
    end
  end

  def provider(client)
    CorporateActionImports::Providers::YahooFinance.new(client:)
  end
end
