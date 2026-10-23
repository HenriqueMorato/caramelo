# frozen_string_literal: true

require "bundler"
require "json"

module DependencyPolicy
  BOUNDED_OPERATORS = %w[~> < <= =].freeze
  FULL_COMMIT_SHA = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i
  EXACT_NPM_VERSION = /\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/

  Result = Struct.new(:errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  class Checker
    def initialize(
      gemfile: Bundler.default_gemfile,
      lockfile: Bundler.default_lockfile,
      package_json: File.expand_path("../package.json", __dir__),
      package_lock: File.expand_path("../package-lock.json", __dir__),
      definition_builder: nil,
      file_reader: File.method(:read),
      json_parser: JSON.method(:parse)
    )
      @gemfile = gemfile
      @lockfile = lockfile
      @package_json = package_json
      @package_lock = package_lock
      @definition_builder = definition_builder || method(:build_definition)
      @file_reader = file_reader
      @json_parser = json_parser
    end

    def call
      Result.new(errors: (bundler_errors + javascript_errors).freeze)
    end

    private

    def build_definition
      Bundler::Definition.build(@gemfile, @lockfile, nil)
    end

    def bundler_errors
      definition = @definition_builder.call
      definition.ensure_equivalent_gemfile_and_lockfile

      definition.dependencies.filter_map do |dependency|
        dependency_error(dependency)
      end
    rescue Bundler::BundlerError => error
      [ "Gemfile.lock is not fresh:\n#{error.message}" ]
    end

    def dependency_error(dependency)
      source = dependency.source
      return git_dependency_error(dependency) if source.is_a?(Bundler::Source::Git)
      return if source.is_a?(Bundler::Source::Path)
      return if bounded_ruby_requirement?(dependency.requirement)

      "#{dependency.name}: registry dependencies must have a bounded version requirement " \
        "(for example, ~> 2.0)"
    end

    def git_dependency_error(dependency)
      options = dependency.source.options
      ref = options["ref"] || options[:ref]
      return if ref&.match?(FULL_COMMIT_SHA)

      "#{dependency.name}: git dependencies must use a full commit SHA via ref:"
    end

    def bounded_ruby_requirement?(requirement)
      requirement.requirements.any? do |operator, _version|
        BOUNDED_OPERATORS.include?(operator)
      end
    end

    def javascript_errors
      package, package_error = parse_manifest(@package_json, "package.json")
      lockfile, lockfile_error = parse_manifest(@package_lock, "package-lock.json")
      errors = [ package_error, lockfile_error ].compact
      return errors unless package && lockfile

      errors.concat(javascript_dependency_errors(package, lockfile))
      errors
    end

    def parse_manifest(path, label)
      [ @json_parser.call(@file_reader.call(path)), nil ]
    rescue JSON::ParserError => error
      [ nil, "#{label} is invalid JSON: #{error.message}" ]
    rescue Errno::ENOENT
      [ nil, "#{label} is missing" ]
    end

    def javascript_dependency_errors(package, lockfile)
      expected = package_dependencies(package)
      packages = lockfile.fetch("packages", {})
      raise KeyError unless packages.key?("")

      root = packages.fetch("")
      actual = package_dependencies(root)
      errors = []

      unless expected == actual
        errors << "package-lock.json root dependencies do not match package.json: " \
          "#{dependency_difference(expected, actual)}"
      end

      expected.each do |name, requirement|
        next if bounded_npm_requirement?(requirement)

        errors << "#{name}: npm dependencies must use an explicit bounded version requirement"
      end
      errors
    rescue KeyError
      [ "package-lock.json is missing its root package metadata" ]
    end

    def package_dependencies(manifest)
      manifest.fetch("dependencies", {}).merge(manifest.fetch("devDependencies", {}))
    end

    def dependency_difference(expected, actual)
      missing = expected.keys - actual.keys
      extra = actual.keys - expected.keys
      changed = expected.keys & actual.keys
      changed.select! { |name| expected.fetch(name) != actual.fetch(name) }

      differences = []
      differences << "missing: #{missing.join(', ')}" if missing.any?
      differences << "extra: #{extra.join(', ')}" if extra.any?
      differences << "changed: #{changed.join(', ')}" if changed.any?
      differences.join("; ")
    end

    def bounded_npm_requirement?(requirement)
      value = requirement.to_s.strip
      return false if value.empty? || %w[* latest].include?(value)
      return true if value.match?(EXACT_NPM_VERSION)

      alternatives = value.split(/\s*\|\|\s*/)
      alternatives.all? do |alternative|
        alternative.match?(/\A[~^]\s*v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/) ||
          alternative.match?(/(?:^|\s)<\s*v?\d+(?:\.\d+){1,2}/)
      end
    end
  end

  def self.check(**options)
    Checker.new(**options).call
  end
end
