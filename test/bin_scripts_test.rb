require "test_helper"
require "open3"
require "tmpdir"

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

    Dir.mktmpdir("reek-clean") do |directory|
      _stdout, init_error, init_status = Open3.capture3("git", "init", "--quiet", directory)
      assert_predicate init_status, :success?, init_error

      empty_tree, hash_error, hash_status = Open3.capture3(
        "git", "-C", directory, "hash-object", "-t", "tree", "--stdin", stdin_data: ""
      )
      assert_predicate hash_status, :success?, hash_error

      stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => "test" }, path.to_s, empty_tree.strip, chdir: directory
      )

      assert_predicate status, :success?, stderr
      assert_includes stdout, "No changed Ruby files under app/ or lib/."
    end
  end
end
