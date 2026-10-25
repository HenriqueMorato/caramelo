source "https://rubygems.org", cooldown: 7

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.4"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft", "~> 1.3"
# Use sqlite3 as the database for Active Record
gem "sqlite3", "~> 2.9"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", "~> 8.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails", "~> 2.2"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails", "~> 2.0"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails", "~> 1.3"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails", "~> 4.6"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder", "~> 2.15"
# CSV is a default gem on older Ruby versions and must be declared explicitly on Ruby 4.
gem "csv", "~> 3.3"
# Store monetary values as integer subunits with ISO currencies [https://github.com/RubyMoney/money-rails]
gem "money-rails", "~> 3.0"
# Generate readable, collision-safe instrument URLs.
gem "friendly_id", "~> 5.7"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", "~> 1.2025", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache", "~> 1.0"
gem "solid_queue", "~> 1.7"
gem "solid_cable", "~> 4.1"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", "~> 1.26", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", "~> 2.12", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", "~> 0.1", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.2"
gem "ruby-vips", "~> 2.0"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", "~> 1.11", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", "~> 0.9", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", "~> 8.1", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", "~> 1.1", require: false

  # Check locale files for missing and unused translations [https://github.com/glebm/i18n-tasks]
  gem "i18n-tasks", "~> 1.1.2", require: false

  # Detect N+1 and unused eager-loading queries while exercising request flows.
  gem "bullet", "~> 8.2"

  # Advisory code-smell reports for selected changed-file checks.
  gem "reek", "~> 6.5", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console", "~> 4.3"

  # Run the development web and CSS processes from Procfile.dev
  gem "foreman", "~> 0.90", require: false
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "axe-core-capybara", "~> 4.14"
  gem "capybara", "~> 3.40"
  gem "selenium-webdriver", "~> 4.51"

  # Report line and branch coverage across test processes [https://github.com/simplecov-ruby/simplecov]
  gem "simplecov", "~> 1.3", require: false
end
