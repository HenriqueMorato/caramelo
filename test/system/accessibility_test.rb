require "application_system_test_case"

class AccessibilityTest < ApplicationSystemTestCase
  test "dashboard has no automatically detectable WCAG violations" do
    with_accessibility_viewport(:desktop) do
      visit root_path
      assert_page_accessible(label: "dashboard")
    end
  end

  test "core populated pages have no automatically detectable WCAG violations" do
    pages = {
      positions: positions_path,
      transactions: transactions_path,
      performance: performance_path,
      institutions: institutions_path,
      instruments: instruments_path,
      instrument: instrument_path(instruments(:voo_arcx)),
      settings: settings_path,
      market_data_health: market_data_health_path,
      trade_new: new_trade_path,
      trade_edit: edit_trade_path(trades(:owner_voo_buy)),
      instrument_edit: edit_instrument_path(instruments(:petr4_bvmf)),
      corporate_action_new: new_instrument_corporate_action_path(instruments(:petr4_bvmf)),
      performance_methodology: performance_methodology_path
    }

    with_accessibility_viewport(:desktop) do
      pages.each do |label, path|
        visit path
        assert_page_accessible(label: label)
      end
    end
  end

  test "core pages fit and scan on a mobile viewport" do
    pages = {
      dashboard: root_path,
      positions: positions_path,
      transactions: transactions_path,
      performance: performance_path,
      instruments: instruments_path,
      instrument: instrument_path(instruments(:voo_arcx)),
      settings: settings_path,
      market_data_health: market_data_health_path,
      trade_new: new_trade_path
    }

    with_accessibility_viewport(:mobile) do
      pages.each do |label, path|
        visit path
        viewport_width = page.evaluate_script("window.innerWidth")
        body_width = page.evaluate_script("document.body.scrollWidth")
        body_client_width = page.evaluate_script("document.body.clientWidth")
        overflowing_elements = page.evaluate_script(<<~JS)
          (() => {
            const viewport = document.body.clientWidth;
            return [...document.querySelectorAll("body *")]
              .map(element => {
                const rect = element.getBoundingClientRect();
                let parent = element.parentElement;
                let clippedBy = null;
                while (parent) {
                  const overflowX = getComputedStyle(parent).overflowX;
                  if (["auto", "scroll", "hidden", "clip"].includes(overflowX)) {
                    clippedBy = parent.className;
                    break;
                  }
                  parent = parent.parentElement;
                }
                return { tag: element.tagName.toLowerCase(), className: element.className,
                  id: element.id, right: Math.round(rect.right), scrollWidth: element.scrollWidth,
                  clientWidth: element.clientWidth, clippedBy }
              })
              .filter(({ right, scrollWidth, clientWidth }) => right > viewport || scrollWidth > clientWidth + 1)
              .sort((left, right) => Math.max(right.right, right.scrollWidth) - Math.max(left.right, left.scrollWidth))
              .slice(0, 8)
          })()
        JS
        assert_operator body_width, :<=, body_client_width,
          "#{label} overflows horizontally: body scroll width #{body_width}px " \
          "elements=#{overflowing_elements.inspect}"
        assert_operator body_client_width, :<=, viewport_width,
          "#{label} body is wider than the viewport: #{body_client_width}px > #{viewport_width}px"
        assert_page_accessible(label: label)
      end
    end
  end

  test "revealed controls are accessible after interaction" do
    with_accessibility_viewport(:mobile) do
      visit settings_path
      find("#reporting-currency-search").click
      assert_selector "[role=option]", visible: true
      assert_page_accessible(label: "settings currency picker")

      visit transactions_path
      find("summary", text: "Add").click
      assert_selector "details[data-testid='add-transaction-menu'][open]"
      assert_page_accessible(label: "transactions add menu")

      visit root_path
      find("summary", text: "Menu").click
      assert_selector "header nav", visible: true
      assert_page_accessible(label: "mobile navigation menu")

      instrument = instruments(:voo_arcx)
      2.times do |index|
        DailyClosingPrice.create!(
          instrument:, trading_date: Date.current - index, close_price: 600 + index,
          currency: instrument.currency, provider: "yahoo_finance", observed_at: Time.current
        )
      end
      visit instrument_path(instrument)
      within "[aria-labelledby='instrument-performance-heading']" do
        click_on "Price history"
      end
      assert_selector "canvas[data-instrument-price-chart-target='canvas']"
      assert_page_accessible(label: "instrument price history")
    end
  end

  test "empty and validation states are accessible" do
    with_accessibility_viewport(:desktop) do
      Trade.where(user: User.owner).delete_all
      CorporateAction.where(user: User.owner).delete_all

      visit positions_path
      assert_text "No positions yet"
      assert_page_accessible(label: "empty positions")

      visit transactions_path
      assert_text "No activity yet"
      assert_page_accessible(label: "empty transactions")

      visit edit_instrument_path(instruments(:petr4_bvmf))
      fill_in "Ticker", with: "voo"
      fill_in "Exchange", with: "arcx"
      fill_in "Currency", with: "ZZZ"
      click_on "Update Instrument"
      assert_text "Currency is invalid"
      assert_page_accessible(label: "instrument validation error")
    end
  end

  test "destructive actions retain an accessible confirmation path" do
    with_accessibility_viewport(:desktop) do
      trade = trades(:owner_voo_buy)
      visit transactions_path

      within "#trade_#{trade.id}" do
        assert_selector "button[data-turbo-confirm='Delete this trade?']", text: "Delete"
        dismiss_confirm "Delete this trade?" do
          click_on "Delete"
        end
      end

      assert_text "Long-term allocation"
      assert_page_accessible(label: "destructive action confirmation")
    end
  end
end
