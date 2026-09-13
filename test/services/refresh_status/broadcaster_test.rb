require "test_helper"

class RefreshStatus::BroadcasterTest < ActiveSupport::TestCase
  test "broadcasts the current presenter to the refresh stream" do
    presenter = Object.new
    calls = []
    with_stubbed_method(RefreshStatus::Presenter, :for, -> { presenter }) do
      with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { calls << :health }) do
        with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*args, **kwargs) { calls << [ args, kwargs ] }) do
          RefreshStatus::Broadcaster.refresh
        end
      end
    end

    args, kwargs = calls.fetch(0)
    assert_equal [ RefreshStatus::Broadcaster::STREAM_NAME ], args
    assert_equal RefreshStatus::Broadcaster::TARGET, kwargs.fetch(:target)
    assert_equal "refresh_status/status_content", kwargs.fetch(:partial)
    assert_equal presenter, kwargs.fetch(:locals).fetch(:status)
    assert kwargs.fetch(:locals).fetch(:broadcast)
    assert_equal :morph, kwargs.fetch(:method)

    activity_args, activity_kwargs = calls.fetch(1)
    assert_equal [ RefreshStatus::Broadcaster::STREAM_NAME ], activity_args
    assert_equal RefreshStatus::Broadcaster::ACTIVITY_TARGET, activity_kwargs.fetch(:target)
    assert_equal "refresh_status/activity_content", activity_kwargs.fetch(:partial)
    assert_equal :health, calls.fetch(2)
  end

  test "does not rebuild health for aggregate recovery progress" do
    health_calls = 0
    with_stubbed_method(RefreshStatus::Presenter, :for, -> { Object.new }) do
      with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { health_calls += 1 }) do
        with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*, **) { }) do
          RefreshStatus::Broadcaster.refresh(
            state: Struct.new(:scope).new("market_data_recovery:1:run"), health: true
          )
        end
      end
    end

    assert_equal 0, health_calls
  end

  test "updates only progress targets during an active batch" do
    calls = []
    state = Struct.new(:scope).new("batch")
    presenter = Struct.new(:progress_label).new("2 active")
    with_stubbed_method(RefreshStatus::Presenter, :for, -> { presenter }) do
      with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*args, **kwargs) { calls << [ args, kwargs ] }) do
        RefreshStatus::Broadcaster.refresh(state:, health: false, progress_only: true)
      end
    end

    assert_equal 2, calls.size
    assert_equal %w[refresh-status-progress health-refresh-progress], calls.map { |call| call.last.fetch(:target) }
    assert_equal [ true, false ], calls.map { |call| call.last.fetch(:locals).fetch(:parentheses) }
    assert_equal [ "2 active", "2 active" ], calls.map { |call| call.last.fetch(:locals).fetch(:label) }
  end

  test "ignores progress from hidden bookkeeping scopes" do
    calls = 0
    with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*, **) { calls += 1 }) do
      %w[current_market_price:42 market_data_recovery:1:run].each do |scope|
        RefreshStatus::Broadcaster.refresh(
          state: Struct.new(:scope).new(scope), health: false, progress_only: true
        )
      end
    end

    assert_equal 0, calls
  end

  test "can broadcast aggregate progress without a triggering state" do
    calls = 0
    presenter = Struct.new(:progress_label).new("1/3")
    with_stubbed_method(RefreshStatus::Presenter, :for, -> { presenter }) do
      with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*, **) { calls += 1 }) do
        RefreshStatus::Broadcaster.refresh(health: false, progress_only: true)
      end
    end

    assert_equal 2, calls
  end

  test "does not repaint global status for per-instrument bookkeeping" do
    calls = 0
    state = Struct.new(:scope).new("current_market_price:42")
    with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { }) do
      with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*, **) { calls += 1 }) do
        RefreshStatus::Broadcaster.refresh(state:)
      end
    end

    assert_equal 0, calls
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
