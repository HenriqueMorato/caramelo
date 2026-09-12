require "test_helper"

class Caramelo::EnvironmentTest < ActiveSupport::TestCase
  test "uses the caramelo variable" do
    with_variable("current") do
      assert_equal "current", Caramelo::Environment.fetch("SAMPLE", default: "default")
    end
  end

  test "uses the default when the variable does not exist" do
    with_variable(nil) do
      assert_equal "default", Caramelo::Environment.fetch("SAMPLE", default: "default")
    end
  end

  private

  def with_variable(value)
    name = "CARAMELO_SAMPLE"
    previous = ENV[name]
    value ? ENV[name] = value : ENV.delete(name)
    yield
  ensure
    previous ? ENV[name] = previous : ENV.delete(name)
  end
end
