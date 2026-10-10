require "axe/api/run"
require "axe/core"

module AccessibilityTestHelper
  WCAG_TAGS = %i[ wcag2a wcag2aa wcag21a wcag21aa wcag22a wcag22aa ].freeze
  ACCESSIBILITY_VIEWPORTS = {
    mobile: [ 390, 844 ],
    desktop: [ 1280, 900 ]
  }.freeze

  def assert_page_accessible(label: nil)
    audit = Axe::Core.new(page).call(
      Axe::API::Run.new.according_to(*AccessibilityTestHelper::WCAG_TAGS)
    )
    context = [ label, page.current_url, accessibility_viewport ].compact.join(" — ")

    assert audit.passed?, "Accessibility violations for #{context}\n#{audit.failure_message}"
  end

  def with_accessibility_viewport(name)
    width, height = AccessibilityTestHelper::ACCESSIBILITY_VIEWPORTS.fetch(name)
    page.current_window.resize_to(width, height)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width:, height:, deviceScaleFactor: 1, mobile: false
    )

    @accessibility_viewport = name
    yield
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    @accessibility_viewport = nil
  end

  private

  attr_reader :accessibility_viewport
end
