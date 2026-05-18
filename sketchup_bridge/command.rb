# frozen_string_literal: true

$VERBOSE = nil

load File.expand_path('utils.rb', __dir__)
load File.expand_path('../scripts/extendable-bed/extendable-bed.rb', __dir__)

cleared = SketchupBridgeUtils.delete_root_proposal_circles
puts "[rebuild] cleared #{cleared} proposal circle(s)." if cleared.positive?

config = Timmerman::ExtendableBed::Config.new(debug_color: :overlaps)
Timmerman::ExtendableBed.clear
Timmerman::ExtendableBed::BedLayout.new(config).create

load File.expand_path('commands/annotate_construction_steps.rb', __dir__)

'OK'
