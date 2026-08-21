User.find_or_create_by!(email_address: Rails.application.config.x.local_folio.owner_email) do |user|
  user.password = SecureRandom.urlsafe_base64(32)
end
