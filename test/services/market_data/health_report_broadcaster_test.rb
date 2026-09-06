require "test_helper"

class MarketData::HealthReportBroadcasterTest < ActiveSupport::TestCase
  test "broadcasts each health entry to its stable row target" do
    entry = Struct.new(:dom_id).new("health-entry-example")
    report = Struct.new(:entries).new([ entry ])
    presenter = Object.new
    calls = []

    with_stubbed_method(Turbo::StreamsChannel, :broadcast_replace_to, ->(*args, **kwargs) { calls << [ args, kwargs ] }) do
      MarketData::HealthReportBroadcaster.refresh(report:, presenter:)
    end

    args, kwargs = calls.fetch(0)
    assert_equal [ RefreshStatus::Broadcaster::STREAM_NAME ], args
    assert_equal "health-entry-example", kwargs.fetch(:target)
    assert_equal "market_data_health/entry", kwargs.fetch(:partial)
    assert_equal entry, kwargs.fetch(:locals).fetch(:entry)
    assert_same presenter, kwargs.fetch(:locals).fetch(:health)
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end
end
