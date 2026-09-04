namespace :position_materializations do
  desc "Rebuild derived positions from authoritative trades"
  task rebuild: :environment do
    results = PositionMaterializations::Rebuild.call
    puts "Rebuilt #{results.size} position materialization(s)."
  end
end
