module Caramelo
  module Environment
    DEFAULT_OWNER_EMAIL = "admin@caramelo.local"
    LEGACY_OWNER_EMAIL = "admin@localfolio.com"
    LEGACY_PREFIX = "LOCALFOLIO_"

    def self.fetch(name, default:)
      ENV.fetch("CARAMELO_#{name}") do
        ENV.fetch("#{LEGACY_PREFIX}#{name}", default)
      end
    end
  end
end
