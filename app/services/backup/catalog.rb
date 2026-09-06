require "json"
require "sqlite3"

module Backup
  class Catalog
    SCHEDULE = "at 3am every day"

    def self.call(configuration: Configuration.default, now: Time.current, verifier: Verifier)
      new(configuration:, now:, verifier:).call
    end

    def initialize(configuration:, now:, verifier:)
      @configuration = configuration
      @now = now
      @verifier = verifier
    end

    def call
      entries = discovered_entries.sort_by { |entry| entry.created_at || Time.at(0) }.reverse
      CatalogResult.new(
        entries:,
        latest: entries.find(&:ready?),
        status: overall_status(entries),
        retention_policy: configuration.retention_policy,
        schedule: ENV.fetch("LOCALFOLIO_BACKUP_SCHEDULE", SCHEDULE)
      )
    end

    private

    attr_reader :configuration, :now, :verifier

    def discovered_entries
      return [] unless configuration.destination.directory?

      configuration.destination.children.filter_map do |path|
        next unless path.directory? && !path.symlink? && !path.basename.to_s.start_with?(".")
        next unless path.join("manifest.json").file?

        entry_for(path)
      end
    end

    def entry_for(path)
      manifest = JSON.parse(path.join("manifest.json").read)
      created_at = Time.iso8601(manifest.fetch("created_at")).in_time_zone
      verified_at = manifest["verified_at"] && Time.iso8601(manifest["verified_at"]).in_time_zone
      status = entry_status(path, manifest)
      Entry.new(
        identifier: Locator.identifier_for(path), created_at:, verified_at:,
        primary_size: artifact_size(path, "primary"), ledger_size: artifact_size(path, "ledger"),
        record_counts: manifest.fetch("record_counts", {}), status:
      )
    rescue JSON::ParserError, ArgumentError, KeyError
      Entry.new(
        identifier: Locator.identifier_for(path), created_at: nil, verified_at: nil,
        primary_size: artifact_size(path, "primary"), ledger_size: artifact_size(path, "ledger"),
        record_counts: {}, status: :invalid
      )
    end

    def entry_status(path, manifest)
      return :invalid unless manifest["verified"]

      verifier.call(directory: path)
      :ready
    rescue Backup::Error, SQLite3::Exception
      :invalid
    end

    def artifact_size(path, artifact)
      file = path.join("#{artifact}.sqlite3")
      file.file? ? file.size : 0
    end

    def overall_status(entries)
      return :missing if entries.empty?
      return :ready if entries.any? { |entry| entry.ready? && entry.created_at.to_date == now.to_date }
      return :stale if entries.any?(&:ready?)

      :invalid
    end
  end
end
