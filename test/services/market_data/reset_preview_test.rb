require "test_helper"

class MarketData::ResetPreviewTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @instrument = instruments(:voo_arcx)
    @target = MarketData::Target.new(kind: :daily_closing_prices, record_id: @instrument.id,
      provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier)
  end

  test "creates and verifies a signed preview" do
    preview = MarketData::ResetPreview.create(
      target: @target, owner: users(:owner), range: Date.new(2026, 9, 1)..Date.new(2026, 9, 2)
    )

    verified = MarketData::ResetPreview.verify(token: preview.token, target: @target, owner: users(:owner))

    assert_equal preview.range, verified.range
    refute_predicate verified, :expired?
  end

  test "verifies a preview when the form submits record id as a string" do
    target = MarketData::Target.new(kind: :current_price, record_id: @instrument.id,
      provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier)
    preview = MarketData::ResetPreview.create(target:, owner: users(:owner))
    submitted_target = MarketData::Target.new(kind: :current_price, record_id: @instrument.id.to_s,
      provider: target.provider)

    verified = MarketData::ResetPreview.verify(token: preview.token, target: submitted_target,
      owner: users(:owner))

    assert_equal target.record_id.to_s, verified.target.record_id.to_s
  end

  test "rejects a preview after the source fingerprint changes" do
    preview = MarketData::ResetPreview.create(target: @target, owner: users(:owner))
    DailyClosingPrice.create!(instrument: @instrument, trading_date: preview.range.begin, close_price: 1,
      currency: @instrument.currency, provider: @target.provider, observed_at: Time.current)

    assert_raises(ArgumentError) do
      MarketData::ResetPreview.verify(token: preview.token, target: @target, owner: users(:owner))
    end
  end

  test "rejects a preview for another target" do
    preview = MarketData::ResetPreview.create(target: @target, owner: users(:owner))
    other = MarketData::Target.new(kind: :daily_closing_prices, record_id: instruments(:petr4_bvmf).id,
      provider: @target.provider)

    assert_raises(ArgumentError) do
      MarketData::ResetPreview.verify(token: preview.token, target: other, owner: users(:owner))
    end
  end

  test "rejects a reversed or non-date range" do
    assert_raises(ArgumentError) do
      MarketData::ResetPreview.create(target: @target, range: Date.current..(Date.current - 1.day))
    end
    assert_raises(ArgumentError) do
      MarketData::ResetPreview.create(target: @target, range: "yesterday")
    end
  end

  test "fingerprints each supported database target" do
    targets = [
      MarketData::Target.new(kind: :daily_closing_prices, record_id: @instrument.id),
      MarketData::Target.new(kind: :historical_exchange_rates, base_currency: "USD", quote_currency: "BRL"),
      MarketData::Target.new(kind: :benchmark_observations, record_id: 1),
      MarketData::Target.new(kind: :portfolio_performance)
    ]

    targets.each do |target|
      digest = MarketData::ResetPreview.send(
        :fingerprint_for, target:, owner: users(:owner), from: Date.current - 1.day, to: Date.current
      )
      assert_match(/\A[0-9a-f]{64}\z/, digest)
    end
  end

  test "fingerprints unknown targets as an empty collection" do
    target = Struct.new(:kind).new(:unknown)
    digest = MarketData::ResetPreview.send(
      :fingerprint_for, target:, owner: users(:owner), from: Date.current, to: Date.current
    )

    assert_equal Digest::SHA256.hexdigest("[]"), digest
  end

  test "fingerprints both currency directions for the selected provider" do
    target = MarketData::Target.new(
      kind: :historical_exchange_rates, base_currency: "USD", quote_currency: "BRL",
      provider: "yahoo_finance_fx"
    )
    date = Date.new(2026, 9, 1)
    attributes = { rate_date: date, rate: 5, observed_at: Time.current, fetched_at: Time.current }
    HistoricalExchangeRate.create!(**attributes, base_currency: "USD", quote_currency: "BRL", provider: target.provider)
    first_digest = MarketData::ResetPreview.send(
      :fingerprint_for, target:, owner: users(:owner), from: date, to: date
    )

    HistoricalExchangeRate.create!(**attributes, base_currency: "BRL", quote_currency: "USD", provider: target.provider)
    refute_equal first_digest, MarketData::ResetPreview.send(
      :fingerprint_for, target:, owner: users(:owner), from: date, to: date
    )
  end

  test "rejects an expired signed preview" do
    verifier = Object.new
    verifier.define_singleton_method(:verify) do |token|
      { "exp" => 1, "target" => @target.to_h, "from" => Date.current.iso8601,
        "to" => Date.current.iso8601, "fingerprint" => "ignored" }
    end

    assert_raises(ArgumentError) do
      MarketData::ResetPreview.verify(token: "expired", target: @target, verifier:)
    end
  end
end
