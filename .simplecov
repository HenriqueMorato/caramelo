# frozen_string_literal: true

SimpleCov.configure do
  load_profile "rails"

  enable_coverage :branch
  cover "{app,lib}/**/*.rb"
  source_in_json false

  group "Presenters", "app/presenters"
  group "Services", "app/services"
  group "Validators", "app/validators"

  command_name ENV.fetch("COVERAGE_COMMAND", "tests")
  # The unit suite can defer formatting until the system suite merges both results.
  formatter false if ENV["COVERAGE_RESULTSET_ONLY"] == "1"
end
