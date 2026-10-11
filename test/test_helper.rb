require "fileutils"

# A focused run must not inherit a recent full-suite result. Merge workflows opt in.
unless ENV["COVERAGE_APPEND"] == "1" || ENV["COVERAGE_RESULTSET_ONLY"] == "1"
  FileUtils.rm_f File.expand_path("../coverage/.resultset.json", __dir__)
end

require "simplecov"
SimpleCov.start

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "active_job/enqueuing"
require_relative "test_helpers/session_test_helper"

module ActiveSupport
  class TestCase
    # The devcontainer's standalone Selenium node exposes one browser slot. Running
    # several remote sessions at once makes later sessions wait for the node timeout.
    requested_workers = ENV["PARALLEL_WORKERS"].to_i
    parallel_workers = if requested_workers.positive?
      requested_workers
    elsif ENV["CAPYBARA_SERVER_PORT"]
      1
    else
      :number_of_processors
    end
    parallelize(workers: parallel_workers)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
