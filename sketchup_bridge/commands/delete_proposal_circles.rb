# frozen_string_literal: true
#
# Delete the rough circle markers the user drew at the model root to indicate
# screw positions. Pairs with `commands/propose_screws_from_circles.rb`:
#
#   1. User draws circles → we run the proposal script → paste screws into code.
#   2. After the user confirms the resulting screws render correctly in the
#      rebuilt bed, run this command to wipe the markers so they stop showing
#      on subsequent rebuilds.
#
# Only circles at the MODEL ROOT are removed (same scope the proposal script
# scans). Circles nested inside EB groups are left alone on purpose; the EB
# clear cycle already rebuilds those roots from scratch.

model = Sketchup.active_model

def full_circle_edges(ents)
  ents.grep(Sketchup::Edge).select do |e|
    curve = e.curve
    next false unless curve.is_a?(Sketchup::ArcCurve)

    sweep = (curve.end_angle - curve.start_angle).abs
    (sweep - 2 * Math::PI).abs < 1e-3
  end
end

edges = full_circle_edges(model.entities)
if edges.empty?
  puts '[delete-proposal-circles] no root-level full circles found — nothing to do.'
  return 'OK'
end

rings = edges.group_by { |e| e.curve.entityID }
puts "[delete-proposal-circles] removing #{rings.size} circle(s) at model root."

model.start_operation('Delete proposal circles', true)
begin
  rings.each_value do |edge_ring|
    alive = edge_ring.select(&:valid?)
    model.entities.erase_entities(alive) unless alive.empty?
  end
  model.commit_operation
rescue StandardError => e
  model.abort_operation
  raise e
end

puts '[delete-proposal-circles] done.'
'OK'
