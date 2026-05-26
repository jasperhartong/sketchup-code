# frozen_string_literal: true
# Snapshot only — never call ExtendableBed.clear / .create here (would erase manual edits).
# Load from command.rb: load File.expand_path('commands/capture_extendable_bed_target.rb', __dir__)

# __dir__ is sketchup_bridge/commands/ when this file is loaded.
sketchup_bridge_dir = File.dirname(__dir__)
repo_root = File.expand_path('..', sketchup_bridge_dir)

eb = File.expand_path('scripts/extendable-bed/extendable-bed.rb', repo_root)
util = File.expand_path('scripts/sketchup_utils/named_group_geometry_snapshot.rb', repo_root)
load eb
load util

Snap = Timmerman::SketchupUtils::NamedGroupGeometrySnapshot
cfg  = Timmerman::ExtendableBed::Config
root_filter = lambda do |g|
  cfg::GROUP_NAME_RE.match?(g.name) || cfg::SINGLE_PAIR_ROOTS.include?(g.name)
end

target = File.expand_path('scripts/extendable-bed/references/extendable_bed_geometry_target.json', repo_root)
Snap.save_snapshot(target, Sketchup.active_model, root_filter: root_filter)

issues = Snap.diff_files(cfg::GEOMETRY_BASELINE_JSON, target, label_a: 'baseline', label_b: 'target')
puts issues.empty? ? 'No diff vs last create' : issues.join("\n")

'OK'
