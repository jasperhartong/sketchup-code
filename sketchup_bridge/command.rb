core = File.expand_path('../scripts/extendable-bed/extendable-bed.rb', __dir__)
load core

config = Timmerman::ExtendableBed::Config.new(debug_color: :off)
Timmerman::ExtendableBed::BedLayout.new(config).clear(Sketchup.active_model)
Timmerman::ExtendableBed::BedLayout.new(config).create(Sketchup.active_model, save_baseline: false)
"OK"
