# frozen_string_literal: true
#
# The SketchUp bridge listener runs this file when `command.rb` is newer than the last run.
# `ruby sketchup_bridge/run_and_wait.rb` touches this file to trigger that and to tie
# `results/result.txt` to this run (avoids stale output).
#
# Default: wipe any proposal circles at the model root, then rebuild the extendable bed.
# To capture manual geometry (no clear/create), temporarily replace the block below with:
#   load File.expand_path('commands/capture_extendable_bed_target.rb', __dir__)
# then `ruby sketchup_bridge/run_and_wait.rb`, then restore this file (e.g. git checkout -- sketchup_bridge/command.rb).

$VERBOSE = nil

load File.expand_path('utils.rb', __dir__)
load File.expand_path('../scripts/extendable-bed/extendable-bed.rb', __dir__)

cleared = SketchupBridgeUtils.delete_root_proposal_circles
puts "[rebuild] cleared #{cleared} proposal circle(s)." if cleared.positive?

config = Timmerman::ExtendableBed::Config.new(debug_paint_faces: false)
Timmerman::ExtendableBed.clear
Timmerman::ExtendableBed::BedLayout.new(config).create
'OK'
