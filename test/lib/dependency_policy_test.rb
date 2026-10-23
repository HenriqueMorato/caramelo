require "test_helper"
require "tmpdir"
require_relative "../../lib/dependency_policy"

class DependencyPolicyTest < ActiveSupport::TestCase
  FakeDependency = Struct.new(:name, :source, :requirement, keyword_init: true)
  FakeRequirement = Struct.new(:requirements)
  FakeDefinition = Struct.new(:dependencies) do
    def ensure_equivalent_gemfile_and_lockfile
      true
    end
  end

  test "the current manifests pass the dependency policy" do
    assert_predicate DependencyPolicy.check, :success?
  end

  test "bounded registry requirements pass and unbounded requirements fail" do
    dependencies = [
      FakeDependency.new(name: "bounded", source: nil, requirement: FakeRequirement.new([ [ "~>", Gem::Version.new("1.0") ] ])),
      FakeDependency.new(name: "unbounded", source: nil, requirement: FakeRequirement.new([ [ ">=", Gem::Version.new("1.0") ] ]))
    ]
    result = checker_for(definition: FakeDefinition.new(dependencies)).call

    assert result.errors.any? { |error| error.start_with?("unbounded: registry dependencies") }
    refute result.errors.any? { |error| error.start_with?("bounded:") }
  end

  test "git dependencies require a full commit SHA and path dependencies are allowed" do
    git_source = Bundler::Source::Git.new(uri: "https://example.com/repo.git", ref: "abc123")
    valid_git_source = Bundler::Source::Git.new(uri: "https://example.com/repo.git", ref: "a" * 40)
    missing_ref_source = Bundler::Source::Git.new(uri: "https://example.com/repo.git")
    path_source = Bundler::Source::Path.new(path: Rails.root.to_s)
    dependencies = [
      FakeDependency.new(name: "invalid-git", source: git_source, requirement: FakeRequirement.new([])),
      FakeDependency.new(name: "valid-git", source: valid_git_source, requirement: FakeRequirement.new([])),
      FakeDependency.new(name: "missing-ref", source: missing_ref_source, requirement: FakeRequirement.new([])),
      FakeDependency.new(name: "path", source: path_source, requirement: FakeRequirement.new([]))
    ]
    result = checker_for(definition: FakeDefinition.new(dependencies)).call

    assert_includes result.errors, "invalid-git: git dependencies must use a full commit SHA via ref:"
    assert_includes result.errors, "missing-ref: git dependencies must use a full commit SHA via ref:"
    refute result.errors.any? { |error| error.start_with?("valid-git:") }
    refute result.errors.any? { |error| error.start_with?("path:") }
  end

  test "a stale lockfile is reported without inspecting dependency bounds" do
    definition = Object.new
    definition.define_singleton_method(:ensure_equivalent_gemfile_and_lockfile) do
      raise Bundler::BundlerError, "lockfile changed"
    end
    definition.define_singleton_method(:dependencies) { raise "should not inspect dependencies" }

    result = checker_for(definition:).call

    assert_equal [ "Gemfile.lock is not fresh:\nlockfile changed" ], result.errors
  end

  test "missing and invalid JavaScript manifests are reported" do
    result = checker_for(
      definition: FakeDefinition.new([]),
      package_json: "/missing/package.json",
      package_lock: "/missing/package-lock.json"
    ).call

    assert_includes result.errors, "package.json is missing"
    assert_includes result.errors, "package-lock.json is missing"

    invalid = checker_for(
      definition: FakeDefinition.new([]),
      package_json: "package.json",
      package_lock: "package-lock.json",
      file_reader: ->(path) { path == "package.json" ? "{" : "{}" }
    ).call
    assert invalid.errors.any? { |error| error.start_with?("package.json is invalid JSON:") }
  end

  test "JavaScript lock metadata and requirement bounds are checked" do
    package = {
      "devDependencies" => {
        "exact" => "1.2.3",
        "caret" => "^1.2.3",
        "range" => ">=1.0.0 <2.0.0",
        "unbounded" => ">=1.0.0",
        "empty" => "",
        "wildcard" => "*"
      }
    }
    lockfile = {
      "packages" => {
        "" => {
          "devDependencies" => package.fetch("devDependencies").except("unbounded", "empty", "wildcard")
            .merge("exact" => "9.9.9", "extra" => "1.0.0")
        }
      }
    }
    result = checker_for(
      definition: FakeDefinition.new([]),
      package_json: "package.json",
      package_lock: "package-lock.json",
      file_reader: ->(path) { JSON.generate(path == "package.json" ? package : lockfile) }
    ).call

    assert result.errors.any? { |error| error.start_with?("package-lock.json root dependencies") }
    assert_includes result.errors, "unbounded: npm dependencies must use an explicit bounded version requirement"
    refute result.errors.any? { |error| error.start_with?("exact:") }
    refute result.errors.any? { |error| error.start_with?("caret:") }
    refute result.errors.any? { |error| error.start_with?("range:") }
  end

  test "a lockfile without root metadata is reported" do
    result = checker_for(
      definition: FakeDefinition.new([]),
      package_json: "package.json",
      package_lock: "package-lock.json",
      file_reader: ->(path) { JSON.generate(path == "package.json" ? {} : { "packages" => {} }) }
    ).call

    assert_includes result.errors, "package-lock.json is missing its root package metadata"
  end

  test "dependency differences describe missing, extra, and changed entries" do
    checker = checker_for(definition: FakeDefinition.new([]))

    assert_equal "missing: b; extra: c; changed: a",
      checker.send(:dependency_difference, { "a" => "1", "b" => "1" }, { "a" => "2", "c" => "1" })
    assert_equal "extra: b",
      checker.send(:dependency_difference, { "a" => "1" }, { "a" => "1", "b" => "1" })
    assert_equal "changed: a",
      checker.send(:dependency_difference, { "a" => "1" }, { "a" => "2" })
    assert_equal "missing: b",
      checker.send(:dependency_difference, { "a" => "1", "b" => "1" }, { "a" => "1" })
  end

  private

  def checker_for(definition:, package_json: "package.json", package_lock: "package-lock.json", file_reader: File.method(:read))
    DependencyPolicy::Checker.new(
      gemfile: "Gemfile",
      lockfile: "Gemfile.lock",
      package_json:,
      package_lock:,
      definition_builder: -> { definition },
      file_reader:,
      json_parser: JSON.method(:parse)
    )
  end
end
