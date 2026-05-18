core = File.expand_path('../scripts/extendable-bed/extendable-bed.rb', __dir__)
load core
config = Timmerman::ExtendableBed::Config.new(debug_color: :overlaps)
Timmerman::ExtendableBed::BedLayout.new(config).clear
Timmerman::ExtendableBed::BedLayout.new(config).create
"OK"
