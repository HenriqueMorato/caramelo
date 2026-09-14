require "test_helper"

class MarketData::HealthReportBroadcasterTest < ActiveSupport::TestCase
  test "broadcasts coherent reports for each health filter" do
    report = Struct.new(:entries).new([])
    replacements = []
    updates = []
    presenter_class = MarketData::HealthReportPresenter
    presenter = Struct.new(:entries).new([ :entry ])

    with_stubbed_method(presenter_class, :new, ->(**) { presenter }) do
      with_stubbed_method(RefreshStatus::Presenter, :for, ->(**) { :activity }) do
        with_stubbed_method(Turbo::StreamsChannel, :broadcast_replace_to, ->(*args, **kwargs) { replacements << [ args, kwargs ] }) do
          with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*args, **kwargs) { updates << [ args, kwargs ] }) do
            MarketData::HealthReportBroadcaster.refresh(report:)
          end
        end
      end
    end

    assert_equal 3, replacements.size
    args, kwargs = replacements.first
    assert_equal [ "market_data_health:all" ], args
    assert_equal MarketData::HealthReportBroadcaster::TARGET, kwargs.fetch(:target)
    assert_equal "market_data_health/report", kwargs.fetch(:partial)
    assert_equal [ :entry ], kwargs.fetch(:locals).fetch(:entries)
    assert_equal :morph, kwargs.fetch(:method)

    activity_args, activity_kwargs = updates.fetch(0)
    assert_equal [ RefreshStatus::Broadcaster::STREAM_NAME ], activity_args
    assert_equal RefreshStatus::Broadcaster::ACTIVITY_TARGET, activity_kwargs.fetch(:target)
    assert_equal :activity, activity_kwargs.fetch(:locals).fetch(:status)
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
