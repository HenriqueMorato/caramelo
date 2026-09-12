module Caramelo
  module Environment
    DEFAULT_OWNER_EMAIL = "admin@caramelo.local"

    def self.fetch(name, default:)
      ENV.fetch("CARAMELO_#{name}", default)
    end
  end
end
