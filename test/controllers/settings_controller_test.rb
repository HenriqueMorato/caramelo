require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  test "shows the owner preference without requiring login" do
    get settings_path

    assert_response :success
    assert_select "h1", "Settings"
    assert_select "form[data-turbo=false]", count: 0
    assert_select "meta[name=turbo-visit-control]", count: 0
    assert_select "select[name='user[reporting_currency]'] option[selected][value=BRL]"
    assert_select "option[value=USD]"
    assert_select "option[value=EUR]"
    assert_select "option[value=BTC]", count: 0
    assert_select "option[value=XAU]", count: 0
    assert_select "select[name='user[reporting_currency]'] option", count: ReportingCurrency::SUPPORTED_CODES.size
    assert_select "section[aria-labelledby=appearance-heading]"
    assert_select "button[data-appearance-mode][aria-pressed=false]", count: 9
    assert_select "script[nonce]", text: /local_folio\.appearance/
    assert_operator response.body.index("local_folio.appearance"), :<, response.body.index("stylesheet")
  end

  test "saves supported currencies and enqueues preparation scoped to the owner" do
    %w[BRL USD EUR].each do |currency|
      assert_enqueued_with(job: PrepareReportingCurrencyJob, args: [ users(:owner), { currency: } ]) do
        patch settings_path, params: { user: { reporting_currency: currency, id: users(:two).id } }
      end

      assert_redirected_to settings_path
      assert_equal currency, User.owner.reporting_currency
      assert_equal "BRL", users(:two).reload.reporting_currency
    end
  end

  test "invalid currency stays on the form with an inline error" do
    assert_no_enqueued_jobs only: PrepareReportingCurrencyJob do
      patch settings_path, params: { user: { reporting_currency: "BTC" } }
    end

    assert_response :unprocessable_content
    assert_select "#reporting-currency-error", "Reporting currency is invalid"
    assert_select "select[aria-invalid=true][autofocus]"
    assert_equal "BRL", User.owner.reporting_currency
  end

  test "keeps a saved preference and offers retry if enqueueing fails" do
    original = PrepareReportingCurrencyJob.method(:enqueue_for)
    PrepareReportingCurrencyJob.define_singleton_method(:enqueue_for) { |**| false }

    patch settings_path, params: { user: { reporting_currency: "EUR" } }

    assert_redirected_to settings_path
    assert_equal "EUR", User.owner.reporting_currency
    assert_includes flash[:alert], "Save again to retry"
  ensure
    PrepareReportingCurrencyJob.define_singleton_method(:enqueue_for, original)
  end
end
