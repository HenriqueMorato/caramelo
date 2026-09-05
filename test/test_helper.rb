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
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
