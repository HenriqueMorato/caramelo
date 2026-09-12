User.owner_or_initialize.tap do |user|
  next unless user.new_record?

  user.password = SecureRandom.urlsafe_base64(32)
  user.save!
end

MarketBenchmark::DEFAULTS.each do |attributes|
  benchmark = MarketBenchmark.find_or_initialize_by(identifier: attributes.fetch(:identifier))
  benchmark.assign_attributes(attributes)
  benchmark.save!
end
