require "fileutils"
require "sqlite3"

module Backup
  class Restorer
    def self.call(directory:, artifact:, destination:, live_path: Configuration.default.source_path)
      new(directory:, artifact:, destination:, live_path:).call
    end

    def initialize(directory:, artifact:, destination:, live_path:)
      @directory = Pathname(directory).expand_path
      @artifact = artifact.to_s
      @destination = Pathname(destination).expand_path
      @live_path = Pathname(live_path).expand_path
    end

    def call
      validate!
      verification = Verifier.call(directory:)
      source = directory.join("#{artifact}.sqlite3")
      FileUtils.mkdir_p(destination.dirname)
      FileUtils.cp(source, temporary_path)
      verify_copy!(temporary_path)
      File.rename(temporary_path, destination)
      Restore.new(directory:, artifact:, restored_path: destination, verification:)
    ensure
      FileUtils.rm_f(temporary_path)
    end

    private

    attr_reader :directory, :artifact, :destination, :live_path

    def validate!
      raise Error, "unknown backup artifact: #{artifact}" unless ARTIFACTS.include?(artifact)
      raise Error, "backup directory is required" unless directory.directory?
      raise Error, "refusing to overwrite the live database" if destination == live_path
      raise Error, "restore destination already exists: #{destination}" if destination.exist?
      raise Error, "restore destination is inside the backup" if destination.to_s.start_with?("#{directory}/")
    end

    def verify_copy!(path)
      database = SQLite3::Database.new(path.to_s, readonly: true)
      raise VerificationError, "restored SQLite database failed integrity check" unless database.get_first_value("PRAGMA integrity_check") == "ok"
    ensure
      database&.close
    end

    def temporary_path = destination.sub_ext(".partial")
  end
end
