class CarameloFormBuilder < ActionView::Helpers::FormBuilder
  def custom_select(method, choices = nil, options = {}, html_options = {})
    select(method, choices, options, custom_select_html_options(html_options))
  end

  def custom_collection_select(method, collection, value_method, text_method, options = {}, html_options = {})
    collection_select(method, collection, value_method, text_method, options, custom_select_html_options(html_options))
  end

  private

  def custom_select_html_options(html_options)
    html_options = html_options.deep_dup
    data = (html_options[:data] || {}).deep_dup
    controllers = data[:controller].to_s.split

    data[:controller] = (controllers + [ "caramelo-select" ]).uniq.join(" ")
    # i18n-tasks-use t("forms.No options")
    data[:caramelo_select_empty_label] ||= @template.t("forms.No options", default: "No options available")
    # i18n-tasks-use t("forms.Select an option")
    data[:caramelo_select_required_message] ||= @template.t("forms.Select an option", default: "Please select an option.")
    html_options[:data] = data
    html_options
  end
end
