bed_script = File.expand_path('../scripts/extendable-bed/extendable-bed.rb', __dir__)
load bed_script

Timmerman::ExtendableBed.clear
Timmerman::ExtendableBed.create

load File.expand_path('utils.rb', __dir__)
SketchupBridgeUtils.take_screenshot(name: "extendable_bed_side_by_side")

"OK — Extendable bed (extended + retracted side by side)"
