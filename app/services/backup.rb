module Backup
  FORMAT_VERSION = 1
  ARTIFACTS = %w[primary ledger].freeze
  DURABLE_TABLES = %w[users institutions instruments trades].freeze

  Error = Class.new(StandardError)
  AlreadyRunning = Class.new(Error)
  NotDue = Class.new(Error)
  VerificationError = Class.new(Error)

  Configuration = Data.define(:source_path, :destination, :retention_count) do
    DEFAULT_RETENTION_COUNT = 7

    def self.default
      database = ActiveRecord::Base.configurations.configs_for(
        env_name: Rails.env, name: "primary"
      ).database

      new(
        source_path: Rails.root.join(database),
        destination: ENV.fetch("LOCALFOLIO_BACKUP_DIRECTORY", Rails.root.join("backups")),
        retention_count: ENV.fetch("LOCALFOLIO_BACKUP_RETENTION", DEFAULT_RETENTION_COUNT).to_i
      )
    end

    def initialize(source_path:, destination:, retention_count:)
      super(
        source_path: Pathname(source_path).expand_path,
        destination: Pathname(destination).expand_path,
        retention_count: Integer(retention_count)
      )
      raise ArgumentError, "backup retention must be positive" unless retention_count.positive?
    end
  end

  Result = Data.define(
    :status, :directory, :primary_path, :ledger_path, :manifest_path,
    :created_at, :record_counts
  )

  Verification = Data.define(:directory, :record_counts, :verified_at)
  Restore = Data.define(:directory, :artifact, :restored_path, :verification)
end
