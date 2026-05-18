core = File.expand_path('../scripts/extendable-bed/extendable-bed.rb', __dir__)
load core
Timmerman::ExtendableBed::BedLayout.new.clear(Sketchup.active_model)
Timmerman::ExtendableBed::BedLayout.new.create(Sketchup.active_model, save_baseline: false)
"OK"
