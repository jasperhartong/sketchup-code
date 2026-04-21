# frozen_string_literal: true
# Adds a floating "Step N" text label above each construction-step BedPair currently in the
# model. Uses the step order and group names from
# scripts/extendable-bed/lib/construction_steps.rb (BedPairCatalog::CONSTRUCTION_SPECS).
#
# Labels are placed on layer "EB_Step_Annotations" and old labels on that layer are erased
# first, so this command is idempotent — rerun it after any `clear` + `create` cycle.
#
# Load from command.rb with:
#   load File.expand_path('commands/annotate_construction_steps.rb', __dir__)

sketchup_bridge_dir = File.dirname(__dir__)
repo_root = File.expand_path('..', sketchup_bridge_dir)
load File.expand_path('scripts/extendable-bed/extendable-bed.rb', repo_root)

STEP_PAIRS = Timmerman::ExtendableBed::BedPairCatalog::CONSTRUCTION_SPECS.map do |spec|
  [spec[:back_name], spec[:front_name], spec[:variant]]
end

STEP_TITLES = [
  'sub-assembly prep legs (flipped)',
  'sub-assembly pre slats (flipped)',
  'combine sub-assemblies (flipped)',
  'add front legs (flipped)',
  'add front under slat (flipped)',
  'Flip correctly',
  'add head/ foot boards'
].freeze

model = Sketchup.active_model
entities = model.entities

groups_by_name = {}
entities.each do |e|
  next unless e.respond_to?(:name) && !e.name.empty?
  groups_by_name[e.name] = e
end

layer_name = Timmerman::ExtendableBed::Config::STEP_ANNOTATIONS_LAYER
layer = model.layers[layer_name] || model.layers.add(layer_name)

model.start_operation('Annotate construction steps', true)

stale = entities.grep(Sketchup::Text).select { |t| t.layer == layer }
entities.erase_entities(stale) unless stale.empty?

added = 0
STEP_PAIRS.each_with_index do |(back_name, front_name, variant), idx|
  back  = groups_by_name[back_name]
  front = groups_by_name[front_name]
  next unless back || front

  bb = Geom::BoundingBox.new
  bb.add(back.bounds)  if back
  bb.add(front.bounds) if front
  next if bb.empty?

  cx = (bb.min.x + bb.max.x) / 2.0
  cy = (bb.min.y + bb.max.y) / 2.0
  top_z = bb.max.z

  anchor = Geom::Point3d.new(cx, cy, top_z)
  leader = Geom::Vector3d.new(0, 0, 300.mm)

  title = STEP_TITLES[idx] || variant.to_s
  label = "Step #{idx + 1}: #{title}"
  txt = entities.add_text(label, anchor, leader)
  txt.layer = layer
  puts "annotated #{label}: back=#{back_name} (#{back ? 'ok' : 'MISSING'}) front=#{front_name} (#{front ? 'ok' : 'MISSING'})"
  added += 1
end

model.commit_operation

puts "Added #{added} / #{STEP_PAIRS.length} step annotations on layer '#{layer_name}'."
'OK'
