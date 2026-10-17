require "test_helper"
require "axe-capybara"
require_relative "support/accessibility_test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include AccessibilityTestHelper

  # The browser talks to the Rails server through a separate connection, so
  # transactional fixtures would hide the setup data from the login request.
  self.use_transactional_tests = false

  # Each browser case resets the shared SQLite database; parallel workers would
  # race while clearing and reloading the fixture rows.
  parallelize(workers: 1)

  setup do
    assert_predicate User.owner, :password_configured?
    assert User.owner.authenticate("password")
    visit new_session_path
    fill_in "Email address", with: User.owner.email_address
    fill_in "Password", with: "password"
    click_on "Sign in"
    assert_current_path root_path
  end

  # Coverage instrumentation and eight parallel browsers can make otherwise
  # completed Turbo navigations exceed Capybara's two-second default.
  Capybara.default_max_wait_time = 5

  if ENV["CAPYBARA_SERVER_PORT"]
    served_by host: "rails-app", port: ENV["CAPYBARA_SERVER_PORT"]

    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: {
      browser: :remote,
      url: "http://#{ENV["SELENIUM_HOST"]}:4444"
    }
  else
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
  end

  private

  def before_setup
    clear_browser_database
    load_browser_fixtures
    super
  end

  def after_teardown
    super
  ensure
    clear_browser_database
  end

  def clear_browser_database
    connection = ActiveRecord::Base.connection
    internal_tables = %w[ar_internal_metadata schema_migrations sqlite_sequence]

    connection.disable_referential_integrity do
      (connection.tables - internal_tables).each do |table|
        connection.delete("DELETE FROM #{connection.quote_table_name(table)}")
      end
    end

    Rails.cache.clear
    connection.disable_query_cache!
  end

  def load_browser_fixtures
    # Rails caches fixture rows; reset that cache because teardown clears the shared database.
    ActiveRecord::FixtureSet.reset_cache
    ActiveRecord::FixtureSet.create_fixtures(
      self.class.fixture_paths, self.class.fixture_table_names, self.class.fixture_class_names
    )
  end

  def choose_caramelo_option(option, from:)
    label = find("label", text: from)
    find("##{label[:for]}", visible: true).click
    find("[role='option']", text: option, visible: true).click
  end

  def assert_caramelo_select_value(value, from:)
    label = find("label", text: from)
    button_id = label[:for]
    native_id = button_id.sub(/-button\z/, "")
    native = find("##{native_id}", visible: :all)
    assert_equal value, native.find("option:checked", visible: :all).text
    assert_selector "##{button_id}", text: value
  end
end
