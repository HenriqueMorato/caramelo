require "test_helper"
require "open3"

class BinScriptsTest < ActiveSupport::TestCase
  test "account and password scripts are executable and expose help" do
    {
      "bin/caramelo-account" => "bin/caramelo-account create EMAIL",
      "bin/caramelo-password" => "bin/caramelo-password setup"
    }.each do |relative_path, usage|
      path = Rails.root.join(relative_path)
      assert_predicate path, :executable?

      stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "test" }, path.to_s, "--help")

      assert_predicate status, :success?, stderr
      assert_includes stdout, usage
    end
  end

  test "reek script is executable and handles a clean Ruby diff" do
    path = Rails.root.join("bin/reek-changed")

    assert_predicate path, :executable?

    stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "test" }, path.to_s, "HEAD")

    assert_predicate status, :success?, stderr
    assert_includes stdout, "No changed Ruby files under app/ or lib/."
  end
end
