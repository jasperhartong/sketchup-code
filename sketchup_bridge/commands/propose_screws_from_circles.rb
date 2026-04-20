# frozen_string_literal: true
#
# Read user-drawn circles (rough indicators) from the active model and propose
# fully-specified `screw` declarations for the extendable bed catalog.
#
# What it does per circle (center point only — diameter is ignored, the screw
# spec drives the visual diameter):
#   1. Identify the HOST EB leaf part + face the center sits on.
#   2. Identify the MATE EB leaf part on the opposite side of the host face
#      (the part the screw fastens into).
#   3. Snap u, v to values built ONLY from 1/3 of `beam_narrow` or `beam_wide`,
#      measured from whichever face edge the circle is closer to. No hardcoded
#      millimetre numbers. If the face's extent along an axis equals
#      beam_narrow or beam_wide (a "section" axis), the candidates are
#      (1/3, 2/3) × that section. For the long axis of a face, candidates are
#      (beam_narrow/3, 2·beam_narrow/3, beam_wide/3, 2·beam_wide/3) measured
#      from whichever end of that axis is nearer to the circle.
#   4. Recommend a shaft_length_index from the spec's shaft_lengths so that
#      the screw tip ends at the END OF THE INDICATED SURFACE — i.e. the
#      far face of the host part along the screw axis. Mate info is printed
#      for context only (to confirm the screw would actually fasten into
#      something) — mate is restricted to the SAME preview root as the host
#      so different previews don't pollute the match.
#
# Load from sketchup_bridge/command.rb:
#   load File.expand_path('commands/propose_screws_from_circles.rb', __dir__)

sketchup_bridge_dir = File.dirname(__dir__)
repo_root = File.expand_path('..', sketchup_bridge_dir)
load File.expand_path('scripts/extendable-bed/extendable-bed.rb', repo_root)

cfg_klass = Timmerman::ExtendableBed::Config
c = cfg_klass.new
BEAM_N = c.beam_narrow.to_f
BEAM_W = c.beam_wide.to_f

model = Sketchup.active_model

# ── 1. Collect candidate circles (selection first, else model root only) ───
def full_circles_from(ents)
  seen = {}
  out = []
  ents.each do |e|
    next unless e.is_a?(Sketchup::Edge)

    curve = e.curve
    next unless curve.is_a?(Sketchup::ArcCurve)
    next if seen[curve.entityID]

    sweep = curve.end_angle - curve.start_angle
    next unless (sweep - 2 * Math::PI).abs < 1e-3

    seen[curve.entityID] = true
    n = curve.normal.clone
    n.normalize!
    out << { entity_id: curve.entityID, center: curve.center, radius: curve.radius, normal: n }
  end
  out
end

sel = model.selection.to_a
circles =
  if sel.any? { |e| e.is_a?(Sketchup::Edge) && e.curve.is_a?(Sketchup::ArcCurve) }
    puts '[propose-screws] using selection'
    full_circles_from(sel.grep(Sketchup::Edge))
  else
    puts '[propose-screws] scanning model ROOT only (no recursion into EB groups)'
    full_circles_from(model.entities)
  end

puts "[propose-screws] found #{circles.size} circle(s)"
if circles.empty?
  puts 'Draw circles on the faces of EB parts (at the model root), then re-run. Tip: select them first to override the root scan.'
  return 'OK'
end

# ── 2. Collect EB leaf parts with both part-LOCAL box and world AABB ──────
# Each leaf carries:
#   :local_min/:local_max — axis-aligned bounding box in the part's LOCAL
#     (pre-transform) frame; this is what the catalog's `face:` symbols and
#     `u`,`v` refer to.
#   :world_min/:world_max — AABB of the transformed corners in world space;
#     used only to find which world part a circle was drawn on and to scope
#     mate search.
#   :world_to_local — inverse of the accumulated transform; lets us turn a
#     world-space circle center/normal back into part-local coordinates.
#   :root — name of the enclosing top-level EB_* group.
def collect_eb_leaves(ents, path_transform, results, root_name)
  ents.each do |e|
    next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)

    sub_ents = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
    sub_t    = path_transform * e.transformation
    name     = e.name.to_s
    effective_root = root_name || (name.start_with?('EB_') ? name : nil)

    has_eb_child = sub_ents.any? do |ch|
      (ch.is_a?(Sketchup::Group) || ch.is_a?(Sketchup::ComponentInstance)) &&
        ch.name.to_s.start_with?('EB | ')
    end

    if name.start_with?('EB | ') && !has_eb_child
      bb = Geom::BoundingBox.new
      sub_ents.each { |s| bb.add(s.bounds) if s.respond_to?(:bounds) }
      local_corners = (0..7).map { |k| bb.corner(k) }
      world_corners = local_corners.map { |pt| pt.transform(sub_t) }
      lxs = local_corners.map(&:x); lys = local_corners.map(&:y); lzs = local_corners.map(&:z)
      wxs = world_corners.map(&:x); wys = world_corners.map(&:y); wzs = world_corners.map(&:z)
      results << {
        name:           name,
        root:           effective_root,
        local_min:      [lxs.min, lys.min, lzs.min],
        local_max:      [lxs.max, lys.max, lzs.max],
        world_min:      [wxs.min, wys.min, wzs.min],
        world_max:      [wxs.max, wys.max, wzs.max],
        world_to_local: sub_t.inverse
      }
    else
      collect_eb_leaves(sub_ents, sub_t, results, effective_root)
    end
  end
end

parts = []
collect_eb_leaves(model.entities, Geom::Transformation.new, parts, nil)
puts "[propose-screws] EB leaf parts: #{parts.size} across #{parts.map { |p| p[:root] }.uniq.size} preview roots"

# ── 3. Helpers ─────────────────────────────────────────────────────────────

# Find the host part + face in PART-LOCAL space.
# Strategy:
#   1. Pick the part whose world AABB the circle's world point lies inside
#      (with a small tolerance), preferring the one whose boundary the circle
#      touches along the circle's normal direction. If the point lies on
#      several parts, take the one whose closest face plane (in local frame)
#      is closest to the circle.
#   2. For the chosen part, transform the circle center to local coords and
#      pick the face (one of the 6 local faces) whose plane is closest AND
#      the circle center projects inside the face rectangle.
def match_host_face_local(world_pt, world_normal, parts)
  candidates = parts.select do |p|
    (0..2).all? { |a| world_pt[a] >= p[:world_min][a] - 2.mm && world_pt[a] <= p[:world_max][a] + 2.mm }
  end

  best = nil
  candidates.each do |p|
    local_c = world_pt.transform(p[:world_to_local])
    local_n = world_normal.transform(p[:world_to_local])
    local_n = Geom::Vector3d.new(local_n.x, local_n.y, local_n.z)
    next if local_n.length.zero?

    local_n.normalize!
    axis =
      if local_n.x.abs >= local_n.y.abs && local_n.x.abs >= local_n.z.abs then 0
      elsif local_n.y.abs >= local_n.z.abs then 1
      else 2
      end

    other = [0, 1, 2] - [axis]
    lc = [local_c.x, local_c.y, local_c.z]
    next unless other.all? { |oa| lc[oa] >= p[:local_min][oa] - 2.mm && lc[oa] <= p[:local_max][oa] + 2.mm }

    d_min = (lc[axis] - p[:local_min][axis]).abs
    d_max = (lc[axis] - p[:local_max][axis]).abs
    side, dist = d_min <= d_max ? [:min, d_min] : [:max, d_max]

    if best.nil? || dist < best[:dist]
      best = { part: p, axis: axis, side: side, dist: dist, local_center: lc }
    end
  end
  best
end

# Find the mate part using a WORLD-space probe just past the host's face on
# the screw axis. The screw axis is local +/- axis direction depending on
# `side`; we transform that local axis direction to world using the host's
# inverse-inverse (i.e. the forward transform derived from world_to_local).
def find_mate(host, axis, side, world_pt, parts)
  local_to_world = host[:world_to_local].inverse
  local_dir = [0.0, 0.0, 0.0]
  local_dir[axis] = (side == :min ? 1.0 : -1.0)
  world_dir = Geom::Vector3d.new(*local_dir).transform(local_to_world)
  world_dir.length.zero? ? (return nil) : world_dir.normalize!

  # March from the circle center along world_dir past the host's far face.
  host_thick = host[:local_max][axis] - host[:local_min][axis]
  probe = Geom::Point3d.new(
    world_pt.x + world_dir.x * (host_thick + 0.2.mm),
    world_pt.y + world_dir.y * (host_thick + 0.2.mm),
    world_pt.z + world_dir.z * (host_thick + 0.2.mm)
  )

  parts.each do |p|
    next if p.equal?(host)
    next unless p[:root] == host[:root]
    next unless (p[:world_min][0]..p[:world_max][0]).cover?(probe.x)
    next unless (p[:world_min][1]..p[:world_max][1]).cover?(probe.y)
    next unless (p[:world_min][2]..p[:world_max][2]).cover?(probe.z)

    return p
  end
  nil
end

# Return {value:, expr:, label:} for the snapped position along one axis of a
# face. `span` = length of the axis within the face (e.g. 44, 69, or 191 mm).
# `circle_v` = circle's coordinate along the axis in part-local space (0..span).
#
# Rule: position at 1/3 or 1/2 of BEAM_NARROW or BEAM_WIDE measured from the
# face end nearest to the circle. Pick the candidate closest to the circle.
def snap_axis(circle_v, span, beam_narrow, beam_wide)
  near_min = circle_v <= span - circle_v
  offsets = [
    { value: beam_narrow / 3.0, expr: 'c.beam_narrow / 3.0', label: 'beam_narrow/3' },
    { value: beam_narrow / 2.0, expr: 'c.beam_narrow / 2.0', label: 'beam_narrow/2' },
    { value: beam_wide   / 3.0, expr: 'c.beam_wide / 3.0',   label: 'beam_wide/3' },
    { value: beam_wide   / 2.0, expr: 'c.beam_wide / 2.0',   label: 'beam_wide/2' }
  ]

  candidates =
    if near_min
      offsets.map { |o| { value: o[:value], expr: o[:expr], label: "#{o[:label]} from min" } }
    else
      span_expr = format_span_expr(span)
      offsets.map do |o|
        value = span - o[:value]
        # span - span/2 = span/2: prefer the simpler expression.
        expr = value.between?(o[:value] - 1e-6, o[:value] + 1e-6) ? o[:expr] : "#{span_expr} - #{o[:expr]}"
        label = value.between?(o[:value] - 1e-6, o[:value] + 1e-6) ? "#{o[:label]} (center)" : "#{o[:label]} from max"
        { value: value, expr: expr, label: label }
      end
    end

  candidates.reject! { |k| k[:value].negative? || k[:value] > span }
  candidates.min_by { |k| (k[:value] - circle_v).abs }
end

# Best-effort mapping of a span (in inches) back to a Config expression.
# Probes the Config class for every zero-arg numeric method and returns the
# first whose value matches the span. Falls back to a commented mm literal.
def format_span_expr(span_inches)
  c = Timmerman::ExtendableBed::Config.new
  preferred = %i[beam_narrow beam_wide plank_thickness outer_corner_leg_height]
  ordered = (preferred + (c.public_methods(false) - preferred)).uniq
  ordered.each do |m|
    next unless c.method(m).arity.zero?

    val = c.public_send(m)
    next unless val.is_a?(Numeric)
    next unless (val.to_f - span_inches).abs < 1e-4

    return "c.#{m}"
  end

  "(#{(span_inches * 25.4).round(1)}.mm /* replace with a Config expression */)"
end

# ── 4. Process each circle ─────────────────────────────────────────────────
spec = c.screw_specs[:eb_pocket_4mm]

circles.each_with_index do |circle, i|
  world_pt = circle[:center]
  best = match_host_face_local(world_pt, circle[:normal], parts)
  if best.nil?
    puts "\n  circle #{i}: NO host face match (center=#{world_pt.to_a.map { |v| (v * 25.4).round(1) }} mm)"
    next
  end

  host = best[:part]
  axis = best[:axis]
  side = best[:side]
  face_key = %i[min_x max_x min_y max_y min_z max_z][axis * 2 + (side == :max ? 1 : 0)]

  dx = host[:local_max][0] - host[:local_min][0]
  dy = host[:local_max][1] - host[:local_min][1]
  dz = host[:local_max][2] - host[:local_min][2]

  lc = best[:local_center]
  lx = lc[0] - host[:local_min][0]
  ly = lc[1] - host[:local_min][1]
  lz = lc[2] - host[:local_min][2]

  u_axis_name, v_axis_name, u_span, v_span, u_local, v_local =
    case face_key
    when :min_x, :max_x then ['Y', 'Z', dy, dz, ly, lz]
    when :min_y, :max_y then ['X', 'Z', dx, dz, lx, lz]
    when :min_z, :max_z then ['X', 'Y', dx, dy, lx, ly]
    end

  u_snap = snap_axis(u_local, u_span, BEAM_N, BEAM_W)
  v_snap = snap_axis(v_local, v_span, BEAM_N, BEAM_W)

  mate = find_mate(host, axis, side, world_pt, parts)
  host_thick = [dx, dy, dz][axis]

  puts "\n  ── circle #{i} ──"
  puts "    host:       #{host[:name]}  (in #{host[:root] || '<root>'})"
  puts "    face:       #{face_key}   (screw head at this face; screw axis perpendicular into host, in part-local frame)"
  puts "    face u/v:   u(#{u_axis_name})=#{(u_span * 25.4).round(1)} mm   v(#{v_axis_name})=#{(v_span * 25.4).round(1)} mm"
  puts "    circle u/v: u=#{(u_local * 25.4).round(1)} mm   v=#{(v_local * 25.4).round(1)} mm"
  puts "    → u snap:   #{(u_snap[:value] * 25.4).round(1)} mm  (#{u_snap[:label]})"
  puts "    → v snap:   #{(v_snap[:value] * 25.4).round(1)} mm  (#{v_snap[:label]})"
  puts "    host thickness along screw axis: #{(host_thick * 25.4).round(1)} mm"
  puts "    mate through host: #{mate ? mate[:name] : '(none — screw stops at host far face)'}"
  puts "    shaft length (only available): #{(spec.shaft_lengths[0].to_f * 25.4).round(1)} mm"
  puts ''
  puts '    # paste inside the appropriate FrameCatalog subclass:'
  puts "    screw 'EB | screw | TODO name | #{i}',"
  puts "          host_name: '#{host[:name]}',"
  puts "          face:      :#{face_key},"
  puts "          u:         #{u_snap[:expr]},"
  puts "          v:         #{v_snap[:expr]},"
  puts "          spec_id:   :eb_pocket_4mm"
end

'OK'
