namespace :position_materializations do
  desc "Rebuild derived positions from authoritative trades"
  task rebuild: :environment do
    users = Caramelo::AccountMode.multi? ? User.all : [ User.default_owner ]
    results = users.flat_map { |user| PositionMaterializations::Rebuild.call(user:) }
    puts "Rebuilt #{results.size} position materialization(s)."
  end
end
