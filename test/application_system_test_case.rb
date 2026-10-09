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

  private

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
