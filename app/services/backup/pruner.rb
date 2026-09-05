require "json"

module Backup
  class Pruner
    def self.call(older_than:, configuration: Configuration.default, now: Time.current, dry_run: false)
      new(older_than:, configuration:, now:, dry_run:).call
    end

    def initialize(older_than:, configuration:, now:, dry_run:)
      @older_than = Integer(older_than)
      raise ArgumentError, "backup age must be positive" unless @older_than.positive?

      @configuration = configuration
      @now = now
      @dry_run = dry_run
    end

    def call
      FileUtils.mkdir_p(configuration.destination, mode: 0o700)
      with_lock do
        deleted = []
        skipped = []
        cutoff = now - older_than.days

        backup_directories.each do |path|
          manifest = parse_manifest(path)
          backup_time = manifest && parsed_time(manifest)
          if manifest && manifest["verified"] && backup_time && backup_time < cutoff
            deleted << path
            FileUtils.rm_rf(path) unless dry_run
          else
            skipped << path
          end
        end

        PruneResult.new(deleted:, skipped:, dry_run:)
      end
    rescue Errno::EAGAIN
      raise AlreadyRunning, "another backup operation is running"
    end

    private

    attr_reader :older_than, :configuration, :now, :dry_run

    def with_lock
      File.open(configuration.destination.join(".localfolio-backup.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        raise Errno::EAGAIN unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    def backup_directories
      configuration.destination.children.select do |path|
        path.directory? && !path.symlink? && path.join("manifest.json").file?
      end
    end

    def parse_manifest(path)
      JSON.parse(path.join("manifest.json").read)
    rescue JSON::ParserError
      nil
    end

    def parsed_time(manifest)
      Time.iso8601(manifest.fetch("created_at")).in_time_zone
    rescue ArgumentError, KeyError
      nil
    end
  end
end
