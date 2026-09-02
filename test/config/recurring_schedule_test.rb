require "test_helper"

class RecurringScheduleTest < ActiveSupport::TestCase
  test "defines market-data schedules for development and production" do
    config = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml"))

    %w[development production].each do |environment|
      schedules = config.fetch(environment)
      assert_equal "every 5 minutes", schedules.fetch("refresh_traded_market_prices").fetch("schedule")
      assert_equal "CaptureMarketBenchmarkObservationsJob", schedules.fetch("capture_market_benchmark_observations").fetch("class")
    end
  end
end
