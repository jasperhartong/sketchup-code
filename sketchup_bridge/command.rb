core = File.expand_path('../scripts/extendable-bed/extendable-bed.rb', __dir__)
load core

config = Timmerman::ExtendableBed::Config.new(debug_color: :off)
bed    = Timmerman::ExtendableBed::BedLayout.new(config)
bed.clear(Sketchup.active_model)
bed.create(Sketchup.active_model)
"OK"
