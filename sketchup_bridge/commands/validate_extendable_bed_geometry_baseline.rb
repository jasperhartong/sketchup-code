# frozen_string_literal: true

# Compares post-create geometry snapshot to a frozen reference JSON (e.g. copied to /tmp
# before a refactor). Loads extendable-bed, clear + create, then diff_files.

ref_json = '/tmp/eb_geometry_baseline_ref.json'
if File.exist?(ref_json)
  eb = File.expand_path('../../scripts/extendable-bed/extendable-bed.rb', __dir__)
  load eb
  Timmerman::ExtendableBed.clear
  Timmerman::ExtendableBed.create

  snap_rb = File.expand_path('../../scripts/sketchup_utils/named_group_geometry_snapshot.rb', __dir__)
  load snap_rb unless defined?(Timmerman::SketchupUtils::NamedGroupGeometrySnapshot)

  cfg = Timmerman::ExtendableBed::Config::GEOMETRY_BASELINE_JSON
  issues = Timmerman::SketchupUtils::NamedGroupGeometrySnapshot.diff_files(
    ref_json, cfg, label_a: 'ref', label_b: 'after_create'
  )

  if issues.empty?
    puts 'PASS: geometry snapshot matches reference'
  else
    puts "FAIL: #{issues.size} issue line(s)"
    puts issues.join("\n")
  end
else
  puts "MISSING_REF: #{ref_json} (copy repo baseline there before refactor)"
end

'OK'
