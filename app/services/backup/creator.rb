require "digest"
require "fileutils"
require "json"
require "sqlite3"

module Backup
  class Creator
    def self.call(configuration: Configuration.default, now: Time.current)
      new(configuration:, now:).call
    end

    def self.due?(configuration: Configuration.default, now: Time.current)
      instance = new(configuration:, now:)
      instance.send(:validate_source!)
      !instance.send(:verified_backup_for_today?)
    end

    def initialize(configuration:, now:)
      @configuration = configuration
      @now = now
    end

    def call
      validate_source!
      FileUtils.mkdir_p(configuration.destination, mode: 0o700)
      FileUtils.chmod(0o700, configuration.destination)
      with_lock do
        return result("not_due") if verified_backup_for_today?

        publish_run(build_run)
      end
    rescue Errno::EAGAIN
      result("already_running")
    rescue StandardError
      remove_temporary_run
      raise
    end

    private

    attr_reader :configuration, :now

    def validate_source!
      return if configuration.source_path.file?

      raise Error, "primary database does not exist: #{configuration.source_path}"
    end

    def with_lock
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        raise Errno::EAGAIN unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    def build_run
      @temporary_directory = configuration.destination.join(".caramelo-#{SecureRandom.hex(8)}")
      FileUtils.mkdir_p(@temporary_directory, mode: 0o700)
      primary = temporary_path("primary.sqlite3")
      ledger = temporary_path("ledger.sqlite3")
      snapshot(primary)
      FileUtils.cp(primary, ledger)
      secure_artifact(primary)
      secure_artifact(ledger)
      filter_ledger(ledger)
      secure_artifact(ledger)
      record_counts = counts(primary, ledger)
      write_manifest(record_counts)
      write_checksums
      verification = Verifier.call(directory: @temporary_directory, allow_unverified: true)
      write_manifest(record_counts, verified: true, verified_at: verification.verified_at)
      write_checksums
      verification = Verifier.call(directory: @temporary_directory)
      Result.new(
        status: "created", directory: nil, primary_path: nil, ledger_path: nil,
        manifest_path: nil, created_at: now, record_counts: verification.record_counts
      )
    end

    def snapshot(path)
      database = SQLite3::Database.new(configuration.source_path.to_s, readonly: true)
      database.busy_timeout = 5_000
      database.execute("VACUUM INTO ?", path.to_s)
    ensure
      database&.close
    end

    def filter_ledger(path)
      database = SQLite3::Database.new(path.to_s)
      database.execute("PRAGMA foreign_keys = OFF")
      owner_id = database.get_first_value(
        "SELECT id FROM users WHERE email_address = ?",
        [ User.owner.email_address ]
      )
      raise Error, "configured owner is missing from the primary database" unless owner_id

      empty_replaceable_tables(database)
      database.execute("DELETE FROM corporate_action_imports WHERE user_id <> ?", [ owner_id ])
      database.execute("DELETE FROM corporate_action_import_scans WHERE user_id <> ?", [ owner_id ])
      database.execute("DELETE FROM corporate_actions WHERE user_id <> ?", [ owner_id ])
      database.execute("DELETE FROM trades WHERE user_id <> ?", [ owner_id ])
      database.execute(<<~SQL, [ owner_id ])
        DELETE FROM institutions
        WHERE user_id <> ? OR id NOT IN (
          SELECT institution_id FROM trades WHERE institution_id IS NOT NULL
          UNION
          SELECT institution_id FROM corporate_actions WHERE institution_id IS NOT NULL
          UNION
          SELECT institution_id FROM corporate_action_imports WHERE institution_id IS NOT NULL
        )
      SQL
      database.execute(<<~SQL)
        DELETE FROM instruments
        WHERE id NOT IN (
          SELECT instrument_id FROM trades
          UNION
          SELECT instrument_id FROM corporate_actions
          UNION
          SELECT instrument_id FROM corporate_action_imports WHERE instrument_id IS NOT NULL
          UNION
          SELECT instrument_id FROM corporate_action_import_scans
        )
      SQL
      database.execute("DELETE FROM users WHERE id <> ?", [ owner_id ])
      database.execute("PRAGMA foreign_keys = ON")
      database.execute("VACUUM")
    ensure
      database&.close
    end

    def empty_replaceable_tables(database)
      tables = database.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten
      (tables - DURABLE_TABLES - %w[schema_migrations ar_internal_metadata sqlite_sequence]).each do |table|
        database.execute("DELETE FROM #{table}")
      end
    end

    def counts(primary, ledger)
      {
        "primary" => Verifier.table_counts(primary),
        "ledger" => Verifier.table_counts(ledger)
      }
    end

    def write_manifest(record_counts, verified: false, verified_at: nil)
      manifest = {
        "format_version" => FORMAT_VERSION,
        "created_at" => now.utc.iso8601(6),
        "environment" => Rails.env,
        "migration_versions" => migration_versions,
        "record_counts" => record_counts,
        "verified" => verified,
        "verified_at" => verified_at&.utc&.iso8601(6)
      }
      File.write(manifest_path, JSON.pretty_generate(manifest), mode: "w", perm: 0o600)
      secure_artifact(manifest_path)
      manifest
    end

    def write_checksums
      checksums = ARTIFACTS.to_h do |artifact|
        path = temporary_path("#{artifact}.sqlite3")
        [ "#{artifact}.sqlite3", Digest::SHA256.file(path).hexdigest ]
      end
      File.write(checksums_path, checksums.map { |name, digest| "#{digest}  #{name}" }.join("\n") + "\n", mode: "w", perm: 0o600)
      secure_artifact(checksums_path)
    end

    def publish_run(result)
      directory = configuration.destination.join(now.utc.strftime("%Y-%m-%dT%H%M%S.%6NZ"))
      File.rename(@temporary_directory, directory)
      @temporary_directory = nil
      prune_verified_runs
      result.with(
        directory:, primary_path: directory.join("primary.sqlite3"),
        ledger_path: directory.join("ledger.sqlite3"), manifest_path: directory.join("manifest.json")
      )
    end

    def prune_verified_runs
      runs = configuration.destination.children.filter_map do |path|
        next unless path.directory? && !path.symlink? && path.join("manifest.json").file?
        next unless JSON.parse(path.join("manifest.json").read)["verified"]

        time = backup_time(path)
        [ path, time ] if time
      rescue JSON::ParserError
        nil
      end
      keep = retention_policy.keep(runs)
      (runs.map(&:first) - keep).each { |path| FileUtils.rm_rf(path) }
    end

    def retention_policy
      configuration.retention_policy
    end

    def backup_time(path)
      Time.iso8601(JSON.parse(path.join("manifest.json").read).fetch("created_at")).in_time_zone
    rescue JSON::ParserError, ArgumentError, KeyError
      nil
    end

    def verified_backup_for_today?
      configuration.destination.children.any? do |path|
        next false unless path.directory? && path.join("manifest.json").file?

        manifest = JSON.parse(path.join("manifest.json").read)
        manifest["verified"] && Time.iso8601(manifest.fetch("created_at")).in_time_zone.to_date == now.to_date
      rescue JSON::ParserError, ArgumentError
        false
      end
    end

    def migration_versions
      ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrations.map { |migration| migration.version.to_s }.sort
    end

    def result(status)
      Result.new(status:, directory: nil, primary_path: nil, ledger_path: nil, manifest_path: nil, created_at: now, record_counts: {})
    end

    def temporary_path(name) = @temporary_directory.join(name)
    def manifest_path = temporary_path("manifest.json")
    def checksums_path = temporary_path("SHA256SUMS")
    def lock_path = configuration.destination.join(".caramelo-backup.lock")

    def remove_temporary_run
      FileUtils.rm_rf(@temporary_directory) if @temporary_directory
    end

    def secure_artifact(path)
      FileUtils.chmod(0o600, path)
    end
  end
end
