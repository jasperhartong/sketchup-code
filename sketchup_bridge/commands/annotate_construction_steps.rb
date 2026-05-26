# frozen_string_literal: true
# Adds floating text labels above each extendable-bed preview pair currently in the model:
#   — construction row: "Step N: …" (BedPairCatalog::CONSTRUCTION_SPECS + STEP_TITLES)
#   — extension row: display names (BedPairCatalog::EXTENSION_SPECS)
#
# Uses group names from scripts/extendable-bed/lib/construction_steps.rb.
#
# Labels are placed on layer "EB_Step_Annotations" and old labels on that layer are erased
# first, so this command is idempotent — rerun it after any `clear` + `create` cycle.
#
# Load from command.rb with:
#   load File.expand_path('commands/annotate_construction_steps.rb', __dir__)

sketchup_bridge_dir = File.dirname(__dir__)
repo_root = File.expand_path('..', sketchup_bridge_dir)
load File.expand_path('scripts/extendable-bed/extendable-bed.rb', repo_root)

STEP_TITLES = [
  'sub-assembly prep legs (flipped)',
  'sub-assembly pre slats (flipped)',
  'combine sub-assemblies (flipped)',
  'add front legs (flipped)',
  'add front under slat (flipped)',
  'Flip correctly',
  'add head/ foot boards',
  'retracted, no pillows'
].freeze

EXTENSION_LABEL_PAIRS = Timmerman::ExtendableBed::BedPairCatalog::EXTENSION_SPECS.map do |spec|
  [spec[:back_name], spec[:front_name], spec[:display_name]]
end.freeze

CONSTRUCTION_LABEL_PAIRS =
  Timmerman::ExtendableBed::BedPairCatalog::CONSTRUCTION_SPECS.each_with_index.map do |spec, idx|
    variant = spec[:variant]
    title = STEP_TITLES[idx] || variant.to_s
    [spec[:back_name], spec[:front_name], "Step #{idx + 1}: #{title}"]
  end.freeze

# Each element is [back_group_name, front_group_name, label_string].
def annotate_eb_preview_labels(entities, layer, groups_by_name, label_pairs, leader)
  added = 0
  label_pairs.each do |back_name, front_name, label_text|
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
    txt = entities.add_text(label_text, anchor, leader)
    txt.layer = layer
    puts "annotated #{label_text.inspect}: back=#{back_name} (#{back ? 'ok' : 'MISSING'}) front=#{front_name} (#{front ? 'ok' : 'MISSING'})"
    added += 1
  end
  added
end

model = Sketchup.active_model
entities = model.entities

groups_by_name = {}
entities.each do |e|
  next unless e.respond_to?(:name) && !e.name.empty?
  groups_by_name[e.name] = e
end

layer_name = Timmerman::ExtendableBed::Config::STEP_ANNOTATIONS_LAYER
layer = model.layers[layer_name] || model.layers.add(layer_name)

model.start_operation('Annotate extendable bed previews', true)

stale = entities.grep(Sketchup::Text).select { |t| t.layer == layer }
entities.erase_entities(stale) unless stale.empty?

leader = Geom::Vector3d.new(0, 0, 300.mm)

added_steps = annotate_eb_preview_labels(
  entities, layer, groups_by_name, CONSTRUCTION_LABEL_PAIRS, leader
)
added_ext = annotate_eb_preview_labels(
  entities, layer, groups_by_name, EXTENSION_LABEL_PAIRS, leader
)

model.commit_operation

n_steps = CONSTRUCTION_LABEL_PAIRS.length
n_ext = EXTENSION_LABEL_PAIRS.length
puts "Added #{added_steps} / #{n_steps} step + #{added_ext} / #{n_ext} extension annotations on layer '#{layer_name}'."
'OK'
