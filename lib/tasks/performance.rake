namespace :performance do
  namespace :observations do
    desc "Rebuild exact daily portfolio performance observations (optional FROM and TO dates)"
    task rebuild: :environment do
      user = if Caramelo::AccountMode.multi?
        email = ENV["EMAIL"].to_s.strip.downcase
        raise ArgumentError, "EMAIL is required in multi-account mode" if email.empty?

        User.find_by!(email_address: email)
      else
        User.default_owner
      end
      first_trade_date = user.trades.minimum(:traded_on) || Date.current
      from = ENV["FROM"].present? ? Date.iso8601(ENV.fetch("FROM")) : first_trade_date
      to = ENV["TO"].present? ? Date.iso8601(ENV.fetch("TO")) : Date.current
      result = Performance::SeriesRefresh.rebuild_now(user:, from:, to:)
      puts "Built #{result.built_count} and reused #{result.skipped_count} daily observations for #{user.email_address} (#{from}–#{to})."
    end
  end
end
