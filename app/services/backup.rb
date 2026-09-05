module Backup
  FORMAT_VERSION = 1
  ARTIFACTS = %w[primary ledger].freeze
  DURABLE_TABLES = %w[users institutions instruments trades].freeze

  Error = Class.new(StandardError)
  AlreadyRunning = Class.new(Error)
  NotDue = Class.new(Error)
  VerificationError = Class.new(Error)

  RetentionPolicy = Data.define(:daily, :weekly, :monthly) do
    DEFAULT_DAILY = 7
    DEFAULT_WEEKLY = 4
    DEFAULT_MONTHLY = 12

    def self.default
      new(
        daily: ENV.fetch("LOCALFOLIO_BACKUP_KEEP_DAILY", DEFAULT_DAILY).to_i,
        weekly: ENV.fetch("LOCALFOLIO_BACKUP_KEEP_WEEKLY", DEFAULT_WEEKLY).to_i,
        monthly: ENV.fetch("LOCALFOLIO_BACKUP_KEEP_MONTHLY", DEFAULT_MONTHLY).to_i
      )
    end

    def initialize(daily:, weekly:, monthly:)
      super(daily: Integer(daily), weekly: Integer(weekly), monthly: Integer(monthly))
      raise ArgumentError, "backup retention values must not be negative" if [ daily, weekly, monthly ].any?(&:negative?)
      raise ArgumentError, "backup retention must keep at least one tier" unless [ daily, weekly, monthly ].any?(&:positive?)
    end

    def keep(runs)
      dated_runs = runs.filter_map { |path, time| [ path, time ] if time }
      keep_daily = representatives(dated_runs, daily) { |time| time.to_date }
      keep_weekly = representatives(dated_runs, weekly) { |time| [ time.to_date.cwyear, time.to_date.cweek ] }
      keep_monthly = representatives(dated_runs, monthly) { |time| [ time.year, time.month ] }
      (keep_daily + keep_weekly + keep_monthly).uniq
    end

    private

    def representatives(runs, limit)
      runs.group_by { |_path, time| yield time }.values
        .sort_by { |entries| entries.map(&:last).max }
        .last(limit)
        .map { |entries| entries.max_by(&:last).first }
    end
  end

  Configuration = Data.define(:source_path, :destination, :retention_policy) do
    def self.default
      database = ActiveRecord::Base.configurations.configs_for(
        env_name: Rails.env, name: "primary"
      ).database

      new(
        source_path: Rails.root.join(database),
        destination: ENV.fetch("LOCALFOLIO_BACKUP_DIRECTORY", Rails.root.join("backups")),
        retention_policy: RetentionPolicy.default
      )
    end

    def initialize(source_path:, destination:, retention_policy: RetentionPolicy.default)
      super(
        source_path: Pathname(source_path).expand_path,
        destination: Pathname(destination).expand_path,
        retention_policy:
      )
    end
  end

  Result = Data.define(
    :status, :directory, :primary_path, :ledger_path, :manifest_path,
    :created_at, :record_counts
  )

  Verification = Data.define(:directory, :record_counts, :verified_at)
  Restore = Data.define(:directory, :artifact, :restored_path, :verification)
  PruneResult = Data.define(:deleted, :skipped, :dry_run)
end
