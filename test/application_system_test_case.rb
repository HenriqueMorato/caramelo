require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
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
end
