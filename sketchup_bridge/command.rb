bed_script = File.expand_path('../scripts/extendable-bed/extendable-bed.rb', __dir__)
load bed_script

Timmerman::ExtendableBed.clear
Timmerman::ExtendableBed.create

"OK — Extendable bed (extended + half + retracted side by side)"
