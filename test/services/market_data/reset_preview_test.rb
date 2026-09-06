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
end
