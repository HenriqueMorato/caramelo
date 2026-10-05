require "test_helper"

class ScheduleCorporateActionImportsJobTest < ActiveJob::TestCase
  test "delegates the recurring pass to the automation coordinator" do
    called = false
    original = CorporateActionImports::Automation.method(:call)
    CorporateActionImports::Automation.define_singleton_method(:call) { called = true }

    ScheduleCorporateActionImportsJob.perform_now

    assert called
  ensure
    CorporateActionImports::Automation.define_singleton_method(:call, original)
  end

  test "uses one scheduler concurrency key" do
    assert_equal "ScheduleCorporateActionImportsJob/corporate-action-imports:scheduler",
      ScheduleCorporateActionImportsJob.new.concurrency_key
  end
end
