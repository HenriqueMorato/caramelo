require "test_helper"
require "tmpdir"

class BackupCatalogTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Rails.cache.clear
    @destination = Pathname(Dir.mktmpdir("localfolio-backup-catalog"))
    @source = Pathname(ActiveRecord::Base.connection_db_config.database)
    @configuration = Backup::Configuration.new(
      source_path: @source,
      destination: @destination,
      retention_policy: Backup::RetentionPolicy.new(daily: 1, weekly: 0, monthly: 0)
    )
  end

  teardown do
    Rails.cache.clear
    FileUtils.rm_rf(@destination)
    FileUtils.rm_rf(@external) if @external
  end

  test "reports a missing destination without exposing its path" do
    configuration = @configuration.with(destination: @destination.join("missing"))

    result = Backup::Catalog.call(configuration:, now: Time.zone.parse("2026-09-05 12:00:00"))

    assert_equal :missing, result.status
    assert_empty result.entries
    assert_nil result.latest
  end

  test "catalogs a verified backup as ready with safe metadata" do
    backup = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))

    result = Backup::Catalog.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 15:00:00"))

    entry = result.entries.first
    assert_equal :ready, result.status
    assert_equal entry, result.latest
    assert entry.ready?
    assert_equal backup.created_at.to_date, entry.created_at.to_date
    assert_operator entry.primary_size, :>, 0
    assert_operator entry.ledger_size, :>, 0
    refute_includes entry.to_s, @destination.to_s
  end

  test "reports an older verified backup as stale" do
    Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-04 12:00:00"))

    result = Backup::Catalog.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))

    assert_equal :stale, result.status
    assert result.latest.ready?
  end

  test "surfaces malformed and unverified runs as invalid" do
    malformed = @destination.join("malformed")
    FileUtils.mkdir_p(malformed)
    malformed.join("manifest.json").write("not json")
    unverified = @destination.join("unverified")
    FileUtils.mkdir_p(unverified)
    unverified.join("manifest.json").write(JSON.generate("verified" => false, "created_at" => "2026-09-05T12:00:00Z"))

    result = Backup::Catalog.call(configuration: @configuration)

    assert_equal :invalid, result.status
    assert_equal 2, result.entries.size
    assert result.entries.all?(&:invalid?)
  end

  test "ignores temporary directories and symlinks" do
    temporary = @destination.join(".localfolio-temporary")
    FileUtils.mkdir_p(temporary)
    temporary.join("manifest.json").write("not json")
    @external = Pathname(Dir.mktmpdir("localfolio-external"))
    @external.join("manifest.json").write("not json")
    symlink = @destination.join("linked")
    symlink.make_symlink(@external)

    assert_empty Backup::Catalog.call(configuration: @configuration).entries
  end

  test "signed locators resolve only the configured direct child" do
    backup = Backup::Creator.call(configuration: @configuration, now: Time.zone.parse("2026-09-05 12:00:00"))
    identifier = Backup::Locator.identifier_for(backup.directory)

    assert_equal backup.directory, Backup::Locator.resolve(identifier, configuration: @configuration)
    assert_raises(Backup::Error) { Backup::Locator.resolve("tampered", configuration: @configuration) }
    assert_raises(Backup::Error) { Backup::Locator.resolve(Backup::Locator.identifier_for(@destination), configuration: @configuration) }
  end

  test "state exposes lifecycle and converts expired running work to interrupted" do
    now = Time.zone.parse("2026-09-05 12:00:00")
    Backup::State.queued!(now:)
    assert Backup::State.current(now:).queued?

    Backup::State.running!(now:)
    assert Backup::State.current(now:).running?

    expired = { "status" => "running", "started_at" => (now - Backup::State::TTL - 1.second).iso8601 }
    Rails.cache.write(Backup::State::KEY, expired)
    state = Backup::State.current(now:)
    assert state.interrupted?
    refute state.active?

    result = Data.define(:created_at).new(created_at: now)
    Backup::State.completed!(result, now:)
    assert Backup::State.current(now:).completed?
    Backup::State.failed!(RuntimeError.new, now:)
    failed = Backup::State.current(now:)
    assert failed.failed?
    assert_equal "RuntimeError", failed.error
  end

  test "ignores malformed cached state" do
    Rails.cache.write(Backup::State::KEY, { "status" => "running", "started_at" => "bad" })

    state = Backup::State.current

    assert state.running?
    assert_nil state.started_at
  end
end
