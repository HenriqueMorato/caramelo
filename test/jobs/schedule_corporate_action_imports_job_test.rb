require "test_helper"

class ScheduleCorporateActionImportsJobTest < ActiveJob::TestCase
  test "delegates the recurring pass to the automation coordinator" do
    called = []
    original = CorporateActionImports::Automation.method(:call)
    CorporateActionImports::Automation.define_singleton_method(:call) { |user:| called << user }

    ScheduleCorporateActionImportsJob.perform_now

    assert_equal [ User.owner ], called
  ensure
    CorporateActionImports::Automation.define_singleton_method(:call, original)
  end

  test "runs one import pass per account in multi mode" do
    called = []
    previous = Rails.application.config.x.caramelo.account_mode
    Rails.application.config.x.caramelo.account_mode = "multi"
    original = CorporateActionImports::Automation.method(:call)
    CorporateActionImports::Automation.define_singleton_method(:call) { |user:| called << user }

    ScheduleCorporateActionImportsJob.perform_now

    assert_equal User.all.to_a, called
  ensure
    CorporateActionImports::Automation.define_singleton_method(:call, original) if original
    Rails.application.config.x.caramelo.account_mode = previous
  end

  test "uses one scheduler concurrency key" do
    assert_equal "ScheduleCorporateActionImportsJob/corporate-action-imports:scheduler",
      ScheduleCorporateActionImportsJob.new.concurrency_key
  end
end
