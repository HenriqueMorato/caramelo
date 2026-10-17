require "test_helper"
require "rake"

class PerformanceTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("performance:observations:rebuild")
    @task = Rake::Task["performance:observations:rebuild"]
    @task.reenable
    @previous_mode = Rails.application.config.x.caramelo.account_mode
    @previous_email = ENV["EMAIL"]
  end

  teardown do
    Rails.application.config.x.caramelo.account_mode = @previous_mode
    ENV["EMAIL"] = @previous_email
  end

  test "normalizes the account email in multi-account mode" do
    Rails.application.config.x.caramelo.account_mode = "multi"
    ENV["EMAIL"] = "ONE@EXAMPLE.COM"
    calls = []
    result = Struct.new(:built_count, :skipped_count).new(1, 2)
    original = Performance::SeriesRefresh.method(:rebuild_now)
    Performance::SeriesRefresh.define_singleton_method(:rebuild_now) do |**arguments|
      calls << arguments
      result
    end

    @task.invoke
    assert_equal users(:one), calls.first.fetch(:user)
  ensure
    Performance::SeriesRefresh.define_singleton_method(:rebuild_now, original) if original
  end
end
