require "digest"
require "json"
require "sqlite3"

module Backup
  class Verifier
    def self.call(directory:, expected_migration_versions: default_migration_versions, allow_unverified: false)
      new(directory:, expected_migration_versions:, allow_unverified:).call
    end

    def self.default_migration_versions
      ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrations.map { |migration| migration.version.to_s }
    end

    def self.table_counts(path)
      database = SQLite3::Database.new(path.to_s, readonly: true)
      tables = database.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").flatten
      tables.to_h { |table| [ table, database.get_first_value("SELECT COUNT(*) FROM #{table}") ] }
    ensure
      database&.close
    end

    def initialize(directory:, expected_migration_versions:, allow_unverified: false)
      @directory = Pathname(directory).expand_path
      @expected_migration_versions = expected_migration_versions.map(&:to_s).sort
      @allow_unverified = allow_unverified
    end

    def call
      manifest = read_manifest
      validate_manifest!(manifest)
      raise VerificationError, "backup is not marked verified" unless manifest["verified"] || allow_unverified

      verify_checksums!
      ARTIFACTS.each { |artifact| verify_database!(artifact_path(artifact), ledger: artifact == "ledger") }
      Verification.new(directory:, record_counts: manifest.fetch("record_counts"), verified_at: Time.current)
    rescue SQLite3::Exception => error
      raise VerificationError, "backup cannot be read: #{error.message}"
    end

    private

    attr_reader :directory, :expected_migration_versions, :allow_unverified

    def read_manifest
      raise VerificationError, "manifest does not exist" unless manifest_path.file?

      JSON.parse(manifest_path.read)
    rescue JSON::ParserError => error
      raise VerificationError, "manifest is invalid: #{error.message}"
    end

    def validate_manifest!(manifest)
      raise VerificationError, "unsupported backup format" unless manifest["format_version"] == FORMAT_VERSION
      raise VerificationError, "manifest migration versions are missing" unless manifest["migration_versions"].is_a?(Array)
      raise VerificationError, "manifest record counts are missing" unless manifest["record_counts"].is_a?(Hash)
      Time.iso8601(manifest.fetch("created_at"))
    rescue ArgumentError, KeyError
      raise VerificationError, "manifest creation time is invalid"
    end

    def verify_checksums!
      checksums = checksums_path.read.lines(chomp: true).to_h { |line| line.split(/\s+/, 2).reverse }
      ARTIFACTS.map { |artifact| "#{artifact}.sqlite3" }.each do |name|
        path = directory.join(name)
        raise VerificationError, "missing backup artifact: #{name}" unless path.file?
        raise VerificationError, "checksum does not match: #{name}" unless Digest::SHA256.file(path).hexdigest == checksums.fetch(name)
      end
    rescue Errno::ENOENT, KeyError
      raise VerificationError, "backup checksums are missing or invalid"
    end

    def verify_database!(path, ledger:)
      database = SQLite3::Database.new(path.to_s, readonly: true)
      raise VerificationError, "SQLite integrity check failed" unless database.get_first_value("PRAGMA integrity_check") == "ok"
      verify_ledger_rows(database) if ledger
      raise VerificationError, "foreign-key check failed" unless database.execute("PRAGMA foreign_key_check").empty?

      versions = database.execute("SELECT version FROM schema_migrations").flatten.map(&:to_s)
      pending = expected_migration_versions - versions
      raise VerificationError, "backup has pending migrations: #{pending.join(', ')}" if pending.any?
    ensure
      database&.close
    end

    def verify_ledger_rows(database)
      owner_id = database.get_first_value("SELECT id FROM users ORDER BY id LIMIT 1")
      raise VerificationError, "ledger has no owner" unless owner_id
      %w[sessions daily_closing_prices historical_exchange_rates current_market_prices market_benchmark_observations].each do |table|
        next unless database.table_info(table).any?
        raise VerificationError, "ledger contains replaceable rows: #{table}" unless database.get_first_value("SELECT COUNT(*) FROM #{table}").zero?
      end
      invalid_trade = database.get_first_value("SELECT 1 FROM trades WHERE user_id <> ? LIMIT 1", [ owner_id ])
      raise VerificationError, "ledger contains unrelated trades" if invalid_trade
      return if database.get_first_value("SELECT COUNT(*) FROM users") == 1

      raise VerificationError, "ledger contains unrelated users"
    end

    def artifact_path(artifact) = directory.join("#{artifact}.sqlite3")
    def manifest_path = directory.join("manifest.json")
    def checksums_path = directory.join("SHA256SUMS")
  end
end
