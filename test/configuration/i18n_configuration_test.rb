require "test_helper"

class I18nConfigurationTest < ActiveSupport::TestCase
  test "loads locale files from nested directories" do
    locale_file = Rails.root.join("config/locales/en/application.yml").to_s

    assert_includes I18n.load_path.map(&:to_s), locale_file
    assert_equal "caramelo", I18n.t("caramelo")
  end

  test "raises when a translation is missing in test" do
    assert Rails.application.config.i18n.raise_on_missing_translations
    assert_raises(I18n::MissingTranslationData) do
      I18n.t("missing.translation.for.test", raise: true)
    end
  end

  test "marks only html translation keys as safe" do
    helper = ApplicationController.helpers
    html = helper.translate(
      "passwords_mailer.reset.Reset instructions_html",
      link: "<strong>reset page</strong>".html_safe,
      expires_in: "15 minutes"
    )
    text = helper.translate(
      "passwords_mailer.reset.Reset instructions",
      url: "https://example.test/reset",
      expires_in: "15 minutes"
    )

    assert_predicate html, :html_safe?
    assert_includes html, "<strong>reset page</strong>"
    refute_predicate text, :html_safe?
  end
end
