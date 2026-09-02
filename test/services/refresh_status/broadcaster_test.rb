require "test_helper"

class RefreshStatus::BroadcasterTest < ActiveSupport::TestCase
  test "broadcasts the current presenter to the refresh stream" do
    presenter = Object.new
    calls = []
    with_stubbed_method(RefreshStatus::Presenter, :for, -> { presenter }) do
      with_stubbed_method(Turbo::StreamsChannel, :broadcast_replace_to, ->(*args, **kwargs) { calls << [ args, kwargs ] }) do
        RefreshStatus::Broadcaster.refresh
      end
    end

    args, kwargs = calls.fetch(0)
    assert_equal [ RefreshStatus::Broadcaster::STREAM_NAME ], args
    assert_equal RefreshStatus::Broadcaster::TARGET, kwargs.fetch(:target)
    assert_equal "refresh_status/status", kwargs.fetch(:partial)
    assert_equal presenter, kwargs.fetch(:locals).fetch(:status)
    assert kwargs.fetch(:locals).fetch(:broadcast)
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
