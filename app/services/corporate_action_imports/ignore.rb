module CorporateActionImports
  class Ignore
    def self.call(import:)
      import.with_lock do
        return import if import.confirmed?

        import.update!(status: :ignored, reviewed_at: Time.current, failure_message: nil)
      end
      import
    end
  end
end
