require_relative "boot"
require_relative "caramelo_environment"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Caramelo
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    generated_secret_path = root.join("storage/.secret_key_base")
    if ENV["SECRET_KEY_BASE"].to_s.empty? && generated_secret_path.file?
      config.secret_key_base = generated_secret_path.read.strip
    end

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.time_zone = "America/Sao_Paulo"
    config.i18n.default_locale = :en
    config.i18n.load_path += Dir[Rails.root.join("config", "locales", "**", "*.yml")]
    config.action_view.default_form_builder = "CarameloFormBuilder"
    owner_email = Caramelo::Environment.fetch("OWNER_EMAIL", default: Caramelo::Environment::DEFAULT_OWNER_EMAIL)
    config.x.caramelo.owner_email = owner_email.strip.downcase
    config.x.caramelo.reporting_currency = "BRL"

    # config.eager_load_paths << Rails.root.join("extras")
  end
end
