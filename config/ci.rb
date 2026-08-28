# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"
  step "Translations: I18n", "bin/i18n-tasks health"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Coverage: Clean", "bin/simplecov clean --quiet"
  step "Tests: Rails", "env COVERAGE_COMMAND=rails-tests COVERAGE_RESULTSET_ONLY=1 bin/rails test"
  step "Tests: System", "env COVERAGE_APPEND=1 COVERAGE_COMMAND=system-tests bin/rails test:system"
  step "Coverage: Combined report", "bin/simplecov report --no-color"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
