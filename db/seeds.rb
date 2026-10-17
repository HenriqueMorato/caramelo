raise ArgumentError, "CARAMELO_OWNER_EMAIL does not match an existing account" if User.owner_configuration_conflict?

User.owner_or_initialize.tap do |user|
  next unless user.new_record?

  user.password = SecureRandom.urlsafe_base64(32)
  user.password_configured_at = nil
  user.save!
end

MarketBenchmark::DEFAULTS.each do |attributes|
  benchmark = MarketBenchmark.find_or_initialize_by(identifier: attributes.fetch(:identifier))
  benchmark.assign_attributes(attributes)
  benchmark.save!
end
