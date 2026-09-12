require "test_helper"

class Caramelo::EnvironmentTest < ActiveSupport::TestCase
  test "prefers the caramelo variable" do
    with_variables("CARAMELO_SAMPLE" => "current", "LOCALFOLIO_SAMPLE" => "legacy") do
      assert_equal "current", Caramelo::Environment.fetch("SAMPLE", default: "default")
    end
  end

  test "supports the legacy variable" do
    with_variables("LOCALFOLIO_SAMPLE" => "legacy") do
      assert_equal "legacy", Caramelo::Environment.fetch("SAMPLE", default: "default")
    end
  end

  test "uses the default when neither variable exists" do
    with_variables do
      assert_equal "default", Caramelo::Environment.fetch("SAMPLE", default: "default")
    end
  end

  private

  def with_variables(values = {})
    names = %w[CARAMELO_SAMPLE LOCALFOLIO_SAMPLE]
    previous = names.to_h { |name| [ name, ENV[name] ] }
    names.each { |name| ENV.delete(name) }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
  end
end
