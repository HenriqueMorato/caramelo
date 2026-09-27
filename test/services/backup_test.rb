require "test_helper"
require "tmpdir"

class BackupTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @destination = Pathname(Dir.mktmpdir("caramelo-backups"))
    @source = Pathname(ActiveRecord::Base.connection_db_config.database)
    @configuration = Backup::Configuration.new(
      source_path: @source,
      destination: @destination,
      retention_policy: Backup::RetentionPolicy.new(daily: 2, weekly: 0, monthly: 0)
    )
  end

  teardown do
    FileUtils.rm_rf(@destination)
    CorporateActionImport.delete_all
    CorporateAction.delete_all
  end

  test "creates and verifies complete and portable artifacts" do
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))

    assert_equal "created", result.status
    assert_path_exists result.primary_path
    assert_path_exists result.ledger_path
    assert_path_exists result.manifest_path
    assert_equal result.directory, result.primary_path.dirname
    verification = Backup::Verifier.call(directory: result.directory)
    assert_equal 3, verification.record_counts.fetch("primary").fetch("users")
    assert_equal 1, verification.record_counts.fetch("ledger").fetch("users")
    assert_equal 0, verification.record_counts.fetch("ledger").fetch("daily_closing_prices")
  end

  test "keeps corporate actions and import reviews in the durable ledger artifact" do
    action = CorporateAction.create!(
      user: users(:owner), instrument: instruments(:petr4_bvmf), kind: :dividend,
      status: :confirmed, paid_on: Date.new(2026, 8, 20), gross_amount_cents: 1_000,
      withholding_tax_cents: 0, net_amount_cents: 1_000, currency: "BRL",
      source: "manual"
    )
    CorporateActionImport.create!(
      user: users(:owner), instrument: action.instrument, corporate_action: action,
      source: "yahoo_finance", source_reference: "backup-review", status: :confirmed,
      kind: "dividend", event_on: Date.new(2026, 8, 18), paid_on: action.paid_on,
      ex_date: action.ex_date, currency: "BRL", gross_amount_cents: 1_000,
      withholding_tax_cents: 0, net_amount_cents: 1_000,
      normalized_data: {}, raw_payload: {}, warnings: []
    )

    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))
    counts = Backup::Verifier.call(directory: result.directory).record_counts.fetch("ledger")

    assert_equal 1, counts.fetch("corporate_actions")
    assert_equal 1, counts.fetch("corporate_action_imports")
  end

  test "requires a valid retention policy" do
    assert_raises(ArgumentError) do
      Backup::RetentionPolicy.new(daily: -1, weekly: 0, monthly: 0)
    end

    assert_raises(ArgumentError) { Backup::RetentionPolicy.new(daily: 0, weekly: 0, monthly: 0) }
  end

  test "ignores retention runs without valid dates" do
    policy = Backup::RetentionPolicy.new(daily: 1, weekly: 1, monthly: 1)

    assert_empty policy.keep([ [ @destination.join("invalid"), nil ] ])
    assert_empty policy.send(:representatives, [], 1) { |time| time.to_date }
  end

  test "does not create a second verified run on the same local day" do
    first = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))
    second = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 15:00:00"))

    assert_equal "created", first.status
    assert_equal "not_due", second.status
  end

  test "retains only the configured number of verified runs" do
    3.times do |index|
      Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-#{index + 5} 12:00:00"))
    end

    runs = @destination.children.select { |path| path.directory? && path.join("manifest.json").file? }
    assert_equal 2, runs.size
  end

  test "retains weekly and monthly representatives without deleting their daily overlap" do
    policy = Backup::RetentionPolicy.new(daily: 1, weekly: 1, monthly: 2)
    configuration = Backup::Configuration.new(source_path: @source, destination: @destination, retention_policy: policy)
    dates = %w[2026-01-15 2026-02-12 2026-03-03]
    dates.each { |date| Backup::Creator.call(configuration:, now: Time.zone.parse("#{date} 12:00:00")) }

    runs = @destination.children.select { |path| path.directory? && path.join("manifest.json").file? }
    assert_equal 2, runs.size
  end

  test "prunes only verified backups older than the requested age" do
    old = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-08-01 12:00:00"))
    recent = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))
    unverified = @destination.join("unverified")
    FileUtils.mkdir_p(unverified)
    unverified.join("manifest.json").write(JSON.generate("verified" => false, "created_at" => "2026-08-01T12:00:00Z"))

    result = Backup::Pruner.call(configuration: @configuration, older_than: 30, now: Time.zone.parse("2026-09-05 12:00:00"))

    assert_equal [ old.directory ], result.deleted
    refute_path_exists old.directory
    assert_path_exists recent.directory
    assert_path_exists unverified
  end

  test "leaves malformed and undated backup manifests untouched" do
    malformed = @destination.join("malformed")
    FileUtils.mkdir_p(malformed)
    malformed.join("manifest.json").write("not json")
    undated = @destination.join("undated")
    FileUtils.mkdir_p(undated)
    undated.join("manifest.json").write(JSON.generate("verified" => true, "created_at" => "bad"))

    result = Backup::Pruner.call(configuration: @configuration, older_than: 1, now: Time.zone.parse("2026-09-05 12:00:00"))

    assert_empty result.deleted
    assert_path_exists malformed
    assert_path_exists undated
  end

  test "rejects a non-positive age and a concurrent prune" do
    assert_raises(ArgumentError) { Backup::Pruner.call(configuration: @configuration, older_than: 0) }

    lock_path = @destination.join(".caramelo-backup.lock")
    FileUtils.mkdir_p(@destination)
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      assert_raises(Backup::AlreadyRunning) do
        Backup::Pruner.call(configuration: @configuration, older_than: 1)
      end
    end
  end

  test "supports a dry-run age prune without deleting" do
    old = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-08-01 12:00:00"))

    result = Backup::Pruner.call(configuration: @configuration, older_than: 30, now: Time.zone.parse("2026-09-05 12:00:00"), dry_run: true)

    assert result.dry_run
    assert_equal [ old.directory ], result.deleted
    assert_path_exists old.directory
  end

  test "restores an artifact to a new isolated destination" do
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))
    restored_path = @destination.join("restored.sqlite3")

    restored = Backup::Restorer.call(directory: result.directory, artifact: :ledger, destination: restored_path, live_path: @source)

    assert_equal restored_path, restored.restored_path
    assert_equal "ledger", restored.artifact
    assert_equal "ok", SQLite3::Database.new(restored_path.to_s, readonly: true).get_first_value("PRAGMA integrity_check")
  end

  test "refuses unsafe restore destinations and unknown artifacts" do
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))

    assert_raises(Backup::Error) { Backup::Restorer.call(directory: result.directory, artifact: "other", destination: @destination.join("copy"), live_path: @source) }
    assert_raises(Backup::Error) { Backup::Restorer.call(directory: result.directory, artifact: "primary", destination: @source, live_path: @source) }
    assert_raises(Backup::Error) { Backup::Restorer.call(directory: result.directory, artifact: "primary", destination: result.directory.join("copy"), live_path: @source) }
    existing = @destination.join("existing.sqlite3")
    existing.write("existing")
    assert_raises(Backup::Error) { Backup::Restorer.call(directory: result.directory, artifact: "primary", destination: existing, live_path: @source) }
    assert_raises(Backup::Error) { Backup::Restorer.call(directory: @destination.join("missing"), artifact: "primary", destination: @destination.join("missing-copy"), live_path: @source) }
  end

  test "rejects a changed artifact checksum" do
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))
    result.primary_path.open("ab") { |file| file.write("invalid") }

    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }
  end

  test "rejects a structurally corrupt SQLite artifact" do
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-06 12:00:00"))
    result.primary_path.open("r+b") do |file|
      file.seek(4096)
      file.write("X")
    end
    rewrite_checksums(result.directory)

    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }
    restorer = Backup::Restorer.new(directory: result.directory, artifact: "primary", destination: @destination.join("copy.sqlite3"), live_path: @source)
    assert_raises(Backup::VerificationError) { restorer.send(:verify_copy!, result.primary_path) }
  end

  test "closes no database when SQLite cannot open one" do
    failure = ->(*) { raise SQLite3::Exception, "cannot open" }
    creator = Backup::Creator.new(configuration: @configuration, now: Time.current)
    restorer = Backup::Restorer.new(directory: @destination, artifact: "primary", destination: @destination.join("copy"), live_path: @source)

    with_stubbed_method(SQLite3::Database, :new, failure) do
      assert_raises(SQLite3::Exception) { creator.send(:snapshot, @destination.join("snapshot.sqlite3")) }
      assert_raises(SQLite3::Exception) { creator.send(:filter_ledger, @destination.join("ledger.sqlite3")) }
      assert_raises(SQLite3::Exception) { Backup::Verifier.table_counts(@source) }
      verifier = Backup::Verifier.new(directory: @destination, expected_migration_versions: [])
      assert_raises(SQLite3::Exception) { verifier.send(:verify_database!, @source, ledger: false) }
      assert_raises(SQLite3::Exception) { restorer.send(:verify_copy!, @source) }
    end
  end

  test "reports an already-running creator" do
    lock_path = @destination.join(".caramelo-backup.lock")
    FileUtils.mkdir_p(@destination)
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))
      assert_equal "already_running", result.status
    end
  end

  test "cleans an interrupted temporary run" do
    creator = Backup::Creator.new(configuration: @configuration, now: Time.current)
    temporary = @destination.join(".interrupted")
    FileUtils.mkdir_p(temporary)
    creator.instance_variable_set(:@temporary_directory, temporary)
    creator.define_singleton_method(:build_run) { raise "interrupted" }

    assert_raises(RuntimeError) { creator.call }
    refute_path_exists temporary
  end

  test "rejects a missing source database" do
    configuration = Backup::Configuration.new(
      source_path: @destination.join("missing.sqlite3"),
      destination: @destination,
      retention_policy: Backup::RetentionPolicy.new(daily: 1, weekly: 0, monthly: 0)
    )

    assert_raises(Backup::Error) { Backup::Creator.call(configuration:) }
  end

  test "rejects a source without the configured owner" do
    source = @destination.join("without-owner.sqlite3")
    FileUtils.cp(@source, source)
    database = SQLite3::Database.new(source.to_s)
    database.execute("PRAGMA foreign_keys = OFF")
    database.execute("DELETE FROM users WHERE email_address = ?", [ User.owner.email_address ])
    database.close
    configuration = Backup::Configuration.new(
      source_path: source,
      destination: @destination,
      retention_policy: Backup::RetentionPolicy.new(daily: 1, weekly: 0, monthly: 0)
    )

    assert_raises(Backup::Error) { Backup::Creator.call(configuration:) }
  end

  test "ignores malformed old manifests while pruning and checking due state" do
    malformed = @destination.join("2026-09-04T000000.000000Z")
    FileUtils.mkdir_p(malformed)
    malformed.join("manifest.json").write("not json")
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))

    assert_equal "created", result.status
    refute Backup::Creator.due?(configuration: @configuration, now: Time.zone.parse("2026-09-05 15:00:00"))
  end

  test "does not prune a verified run with an invalid creation time" do
    invalid = @destination.join("invalid")
    FileUtils.mkdir_p(invalid)
    invalid.join("manifest.json").write(JSON.generate("verified" => true, "created_at" => "bad"))

    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))

    assert_equal "created", result.status
    assert_path_exists invalid
  end

  test "does not prune an unverified run during automatic retention" do
    unverified = @destination.join("unverified")
    FileUtils.mkdir_p(unverified)
    unverified.join("manifest.json").write(JSON.generate("verified" => false, "created_at" => "2026-08-01T12:00:00Z"))

    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))

    assert_equal "created", result.status
    assert_path_exists unverified
  end

  test "rejects malformed manifests, checksums, and databases" do
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))
    manifest = result.manifest_path.read

    result.manifest_path.write(manifest.sub('"created_at":', '"created_at":"bad","ignored":'))
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }

    result.manifest_path.write(manifest)
    result.directory.join("SHA256SUMS").delete
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }

    result.directory.join("manifest.json").write("{")
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }

    result.manifest_path.write(manifest)
    result.primary_path.binwrite("not a sqlite database")
    rewrite_checksums(result.directory)
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }
  end

  test "rejects unsupported or incomplete manifests" do
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-07 12:00:00"))
    manifest = JSON.parse(result.manifest_path.read)

    manifest["format_version"] = 99
    result.manifest_path.write(JSON.generate(manifest))
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }

    manifest["format_version"] = Backup::FORMAT_VERSION
    manifest.delete("migration_versions")
    result.manifest_path.write(JSON.generate(manifest))
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }

    manifest["migration_versions"] = []
    manifest.delete("record_counts")
    result.manifest_path.write(JSON.generate(manifest))
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }
  end

  test "verifier accepts an explicitly provisional manifest" do
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-08 12:00:00"))
    manifest = JSON.parse(result.manifest_path.read)
    manifest["verified"] = false
    result.manifest_path.write(JSON.generate(manifest))

    assert Backup::Verifier.call(directory: result.directory, allow_unverified: true)
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }
  end

  test "rejects missing artifacts, pending migrations, and invalid ledger contents" do
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: @destination.join("missing")) }

    result = backup_for("2026-09-09")
    result.primary_path.delete
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }

    result = backup_for("2026-09-10")
    assert_raises(Backup::VerificationError) do
      Backup::Verifier.call(directory: result.directory, expected_migration_versions: [ "99999999999999" ])
    end

    result = backup_for("2026-09-11")
    database = SQLite3::Database.new(result.primary_path.to_s)
    database.execute("PRAGMA foreign_keys = OFF")
    database.execute("INSERT INTO sessions (user_id, created_at, updated_at) VALUES (?, ?, ?)", [ 999_999, Time.current.utc.iso8601, Time.current.utc.iso8601 ])
    database.close
    rewrite_checksums(result.directory)
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }

    result = backup_for("2026-09-12")
    database = SQLite3::Database.new(result.ledger_path.to_s)
    database.execute("PRAGMA foreign_keys = OFF")
    database.execute("DELETE FROM trades")
    database.execute("DELETE FROM institutions")
    database.execute("DELETE FROM instruments")
    database.execute("DELETE FROM users")
    database.close
    rewrite_checksums(result.directory)
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }

    result = backup_for("2026-09-13")
    database = SQLite3::Database.new(result.ledger_path.to_s)
    database.execute("PRAGMA foreign_keys = OFF")
    database.execute("UPDATE trades SET user_id = 999_999 WHERE id = (SELECT id FROM trades LIMIT 1)")
    database.close
    rewrite_checksums(result.directory)
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }

    result = backup_for("2026-09-14")
    database = SQLite3::Database.new(result.ledger_path.to_s)
    database.execute("INSERT INTO sessions (user_id, created_at, updated_at) VALUES (?, ?, ?)", [ users(:owner).id, Time.current.utc.iso8601, Time.current.utc.iso8601 ])
    database.close
    rewrite_checksums(result.directory)
    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }
  end

  test "rejects unrelated users in the ledger" do
    result = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))
    database = SQLite3::Database.new(result.ledger_path.to_s)
    timestamp = Time.current.utc.iso8601
    database.execute("INSERT INTO users (email_address, password_digest, created_at, updated_at) VALUES (?, ?, ?, ?)", [ "unrelated@example.com", "digest", timestamp, timestamp ])
    database.close
    rewrite_checksums(result.directory)

    assert_raises(Backup::VerificationError) { Backup::Verifier.call(directory: result.directory) }
  end

  test "scheduler claims a new day and does not claim it twice" do
    creator = Class.new do
      def self.due?(**)
        true
      end
    end
    job = Class.new do
      def self.set(**)
        self
      end

      def self.perform_later
        true
      end
    end

    now = Time.zone.parse("2099-09-05 12:00:00")
    assert Backup::Scheduler.enqueue_if_due(now:, creator:, job:)
    refute Backup::Scheduler.enqueue_if_due(now:, creator:, job:)
    Rails.cache.delete("#{Backup::Scheduler::KEY_PREFIX}#{now.to_date.iso8601}")
  end

  test "scheduler skips a day that is not due" do
    creator = Class.new do
      def self.due?(**)
        false
      end
    end

    refute Backup::Scheduler.enqueue_if_due(now: Time.zone.parse("2099-09-07 12:00:00"), creator:)
  end

  test "scheduler re-raises a due check failure without a cache claim" do
    creator = Class.new do
      def self.due?(**)
        raise "source unavailable"
      end
    end

    assert_raises(RuntimeError) { Backup::Scheduler.enqueue_if_due(now: Time.zone.parse("2099-09-08 12:00:00"), creator:) }
  end

  test "scheduler releases its claim when enqueueing fails" do
    creator = Class.new do
      def self.due?(**)
        true
      end
    end
    job = Class.new do
      def self.set(**)
        raise "queue unavailable"
      end
    end
    now = Time.zone.parse("2099-12-31 12:00:00")

    assert_raises(RuntimeError) { Backup::Scheduler.enqueue_if_due(now:, creator:, job:) }
    refute Rails.cache.exist?("#{Backup::Scheduler::KEY_PREFIX}#{now.to_date.iso8601}")
  ensure
    Rails.cache.delete("#{Backup::Scheduler::KEY_PREFIX}#{now.to_date.iso8601}")
  end

  test "backup job delegates creation" do
    previous = ENV["CARAMELO_BACKUP_DIRECTORY"]
    ENV["CARAMELO_BACKUP_DIRECTORY"] = @destination.to_s

    CreateBackupJob.perform_now

    assert @destination.children.any? { |path| path.directory? }
  ensure
    ENV["CARAMELO_BACKUP_DIRECTORY"] = previous
  end

  test "backup job records failure before re-raising creation errors" do
    error = RuntimeError.new("backup unavailable")

    with_stubbed_method(Backup::Creator, :call, ->(**) { raise error }) do
      assert_raises(RuntimeError) { CreateBackupJob.perform_now }
    end

    state = Backup::State.current
    assert state.failed?
    assert_equal "RuntimeError", state.error
  end

  private

  def rewrite_checksums(directory)
    checksums = Backup::ARTIFACTS.to_h do |artifact|
      path = directory.join("#{artifact}.sqlite3")
      [ "#{artifact}.sqlite3", Digest::SHA256.file(path).hexdigest ]
    end
    directory.join("SHA256SUMS").write(checksums.map { |name, digest| "#{digest}  #{name}" }.join("\n") + "\n")
  end

  def backup_for(date)
    Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("#{date} 12:00:00"))
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
