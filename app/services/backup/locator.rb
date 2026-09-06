module Backup
  class Locator
    PURPOSE = "backup-run"

    def self.identifier_for(directory)
      verifier.generate(Pathname(directory).basename.to_s, purpose: PURPOSE)
    end

    def self.resolve(identifier, configuration: Configuration.default)
      basename = verifier.verify(identifier, purpose: PURPOSE)
      raise Error, "invalid backup identifier" if basename.blank?
      raise Error, "invalid backup identifier" unless basename.match?(/\A[\w.-]+\z/) && !basename.start_with?(".")

      candidate = configuration.destination.join(basename)
      root = configuration.destination.realpath
      raise Error, "invalid backup location" unless candidate.parent.realpath == root
      raise Error, "backup does not exist" unless candidate.directory? && !candidate.symlink?

      candidate
    rescue ActiveSupport::MessageVerifier::InvalidSignature, Errno::ENOENT
      raise Error, "invalid backup identifier"
    end

    def self.verifier
      Rails.application.message_verifier(:backup_run)
    end
    private_class_method :verifier
  end
end
