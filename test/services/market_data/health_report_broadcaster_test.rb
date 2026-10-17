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

  test "scopes multi-account broadcasts to the report owner" do
    report = Struct.new(:entries).new([])
    replacements = []
    updates = []
    owner = users(:two)

    with_stubbed_method(Caramelo::AccountMode, :multi?, -> { true }) do
      with_stubbed_method(MarketData::HealthReportPresenter, :new, ->(**) { Struct.new(:entries).new([]) }) do
        with_stubbed_method(Turbo::StreamsChannel, :broadcast_replace_to, ->(*args, **) { replacements << args }) do
          with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*args, **) { updates << args }) do
            MarketData::HealthReportBroadcaster.refresh(report:, owner:)
          end
        end
      end
    end

    assert_equal [ "market_data_health:#{owner.id}:all" ], replacements.first
    assert_equal [ "refresh_status:#{owner.id}" ], updates.first
  end

  test "broadcasts a fresh health report to every configured account in multi mode" do
    replacements = []
    updates = []
    report = Struct.new(:entries).new([])

    with_stubbed_method(Caramelo::AccountMode, :multi?, -> { true }) do
      with_stubbed_method(MarketData::HealthReport, :for, ->(owner:) { report }) do
        with_stubbed_method(MarketData::HealthReportPresenter, :new, ->(**) { Struct.new(:entries).new([]) }) do
          with_stubbed_method(RefreshStatus::Presenter, :for, ->(**) { :activity }) do
            with_stubbed_method(Turbo::StreamsChannel, :broadcast_replace_to, ->(*args, **) { replacements << args }) do
              with_stubbed_method(Turbo::StreamsChannel, :broadcast_update_to, ->(*args, **) { updates << args }) do
                MarketData::HealthReportBroadcaster.refresh
              end
            end
          end
        end
      end
    end

    assert_equal User.where.not(password_configured_at: nil).count * 3, replacements.size
    assert_equal User.where.not(password_configured_at: nil).count, updates.size
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
