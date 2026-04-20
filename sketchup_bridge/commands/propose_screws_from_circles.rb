# frozen_string_literal: true
#
# Read user-drawn circles (rough indicators) from the active model and emit
# ready-to-paste `screw` declarations for the extendable bed catalog.
#
# Per circle (center point only — diameter is ignored):
#   1. Identify the HOST EB leaf part + face the center sits on.
#   2. Identify the MATE EB leaf part past the host's far face (same preview
#      root only) — printed for context.
#   3. Snap u/v to 1/3 or 1/2 of `beam_narrow` or `beam_wide`, measured from
#      whichever face edge the circle is closer to, emitted as a Config
#      expression (no hardcoded mm).
#
# Heuristics the command applies so the agent can just paste:
#   - Circles with the same (host_name, face) are grouped into ONE cluster.
#   - Within a cluster, when u-snaps (or v-snaps) form a symmetric pair that
#     sums to the face span, an iteration block is emitted (u-only, v-only,
#     or nested u×v for 4-corner layouts).
#   - Target `FrameCatalog` subclass is guessed from host name tokens.
#   - A method name and `assemble` call are suggested.
#   - Circles whose host is already an `EB | screw | …` group are reported
#     as "already implemented" and skipped (happens on re-runs after a
#     rebuild snaps the circle to the new screw's face).
#
# Load from sketchup_bridge/command.rb:
#   load File.expand_path('commands/propose_screws_from_circles.rb', __dir__)

$VERBOSE = nil

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
    full_circles_from(model.entities)
  end

if circles.empty?
  puts '[propose-screws] no circles found. Draw full circles on EB part faces at the model root, then re-run.'
  return 'OK'
end

# ── 2. Collect EB leaf parts with both part-LOCAL box and world AABB ──────
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

# ── 3. Host/face/mate/snap helpers ────────────────────────────────────────
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

def find_mate(host, axis, side, world_pt, parts)
  local_to_world = host[:world_to_local].inverse
  local_dir = [0.0, 0.0, 0.0]
  local_dir[axis] = (side == :min ? 1.0 : -1.0)
  world_dir = Geom::Vector3d.new(*local_dir).transform(local_to_world)
  world_dir.length.zero? ? (return nil) : world_dir.normalize!

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

# Snap to 1/3 or 1/2 of beam_narrow or beam_wide, from the nearer face end.
# Returns nil if the face is too small to host any snap value.
def snap_axis(circle_v, span, beam_narrow, beam_wide)
  near_min = circle_v <= span - circle_v
  offsets = [
    { value: beam_narrow / 3.0, expr: 'c.beam_narrow / 3.0' },
    { value: beam_narrow / 2.0, expr: 'c.beam_narrow / 2.0' },
    { value: beam_wide   / 3.0, expr: 'c.beam_wide / 3.0' },
    { value: beam_wide   / 2.0, expr: 'c.beam_wide / 2.0' }
  ]

  candidates =
    if near_min
      offsets.map { |o| { value: o[:value], expr: o[:expr] } }
    else
      span_expr = format_span_expr(span)
      offsets.map do |o|
        value = span - o[:value]
        expr = value.between?(o[:value] - 1e-6, o[:value] + 1e-6) ? o[:expr] : "#{span_expr} - #{o[:expr]}"
        { value: value, expr: expr }
      end
    end

  candidates.reject! { |k| k[:value].negative? || k[:value] > span }
  return nil if candidates.empty?

  candidates.min_by { |k| (k[:value] - circle_v).abs }
end

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

# ── 4. Heuristics for the output ──────────────────────────────────────────
def frame_for(host_name)
  tokens = host_name.split(' | ').map(&:downcase)
  return 'BackFrame'  if tokens.any? { |t| %w[head back sister mid behind].include?(t) }
  return 'FrontFrame' if tokens.any? { |t| %w[foot front under].include?(t) }

  'FrameCatalog (pick subclass manually)'
end

# "EB | beam | foot | cap"         → "foot_cap"
# "EB | leg | head | -X | inset"   → "head_mx_inset"
def host_slug(name)
  tokens = name.split(' | ')
  tokens = tokens[1..] || []
  tokens = tokens.drop(1) if %w[beam leg plank pillow slat screw].include?(tokens.first&.downcase)
  tokens
    .join('_')
    .downcase
    .gsub('+', 'p')
    .gsub('-', 'm')
    .gsub(/[^a-z0-9]+/, '_')
    .squeeze('_')
    .sub(/^_|_$/, '')
end

def symmetric_pair?(values, span, tol = 0.5.mm)
  return false unless values.size == 2

  (values.sum - span).abs < tol
end

# ── 5. Group circles into clusters ────────────────────────────────────────
clusters = {} # key = [host_name, face_key]
already = []
skipped = []

circles.each_with_index do |circle, i|
  world_pt = circle[:center]
  best = match_host_face_local(world_pt, circle[:normal], parts)

  if best.nil?
    skipped << "circle #{i}: no host face match — draw it on an EB face"
    next
  end

  host = best[:part]
  if host[:name].start_with?('EB | screw | ')
    already << host[:name]
    next
  end

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

  u_axis, v_axis, u_span, v_span, u_local, v_local =
    case face_key
    when :min_x, :max_x then ['Y', 'Z', dy, dz, ly, lz]
    when :min_y, :max_y then ['X', 'Z', dx, dz, lx, lz]
    when :min_z, :max_z then ['X', 'Y', dx, dy, lx, ly]
    end

  u_snap = snap_axis(u_local, u_span, BEAM_N, BEAM_W)
  v_snap = snap_axis(v_local, v_span, BEAM_N, BEAM_W)
  if u_snap.nil? || v_snap.nil?
    skipped << "circle #{i}: face too small to host a snap (host #{host[:name]}, face :#{face_key})"
    next
  end

  key = [host[:name], face_key]
  clusters[key] ||= {
    u_axis: u_axis, v_axis: v_axis, u_span: u_span, v_span: v_span,
    mate: find_mate(host, axis, side, world_pt, parts), entries: []
  }
  clusters[key][:entries] << { u_snap: u_snap, v_snap: v_snap }
end

# ── 6. Emit one compact block per cluster ─────────────────────────────────
def emit_cluster(host, face_key, info)
  entries = info[:entries]
  u_axis  = info[:u_axis]
  v_axis  = info[:v_axis]
  slug    = host_slug(host)
  method  = "_#{slug}_#{face_key}_screws"
  frame   = frame_for(host)

  us = entries.map { |e| e[:u_snap] }.uniq { |s| s[:value].round(3) }.sort_by { |s| s[:value] }
  vs = entries.map { |e| e[:v_snap] }.uniq { |s| s[:value].round(3) }.sort_by { |s| s[:value] }

  u_mirror = symmetric_pair?(us.map { |s| s[:value] }, info[:u_span])
  v_mirror = symmetric_pair?(vs.map { |s| s[:value] }, info[:v_span])

  puts ''
  puts "── #{host} @ :#{face_key}   (#{entries.size} circle#{'s' unless entries.size == 1})"
  puts "   target: #{frame}    suggested method: #{method}"
  puts "   mate:   #{info[:mate] ? info[:mate][:name] : '(none — screw exits into open air)'}"
  puts '   ready to paste:'
  puts ''
  puts "      # add to #{frame}#assemble:"
  puts "      #{method}"
  puts ''
  puts "      # private method:"
  puts "      def #{method}"

  name_tpl = "EB | screw | #{slug.tr('_', ' ')} | #{face_key}"

  if u_mirror && v_mirror && entries.size == 4
    puts "        { '-#{u_axis}' => #{us[0][:expr]}, '+#{u_axis}' => #{us[1][:expr]} }.each do |u_side, u|"
    puts "          { '-#{v_axis}' => #{vs[0][:expr]}, '+#{v_axis}' => #{vs[1][:expr]} }.each do |v_side, v|"
    puts "            screw \"#{name_tpl} | \#{u_side}\#{v_side}\","
    puts "                  host_name: '#{host}',"
    puts "                  face:      :#{face_key},"
    puts "                  u:         u,"
    puts "                  v:         v,"
    puts '                  spec_id:   :eb_pocket_4mm'
    puts '          end'
    puts '        end'
  elsif u_mirror && vs.size == 1
    puts "        { '-#{u_axis}' => #{us[0][:expr]}, '+#{u_axis}' => #{us[1][:expr]} }.each do |side, u|"
    puts "          screw \"#{name_tpl} | \#{side}\","
    puts "                host_name: '#{host}',"
    puts "                face:      :#{face_key},"
    puts '                u:         u,'
    puts "                v:         #{vs[0][:expr]},"
    puts '                spec_id:   :eb_pocket_4mm'
    puts '        end'
  elsif v_mirror && us.size == 1
    puts "        { '-#{v_axis}' => #{vs[0][:expr]}, '+#{v_axis}' => #{vs[1][:expr]} }.each do |side, v|"
    puts "          screw \"#{name_tpl} | \#{side}\","
    puts "                host_name: '#{host}',"
    puts "                face:      :#{face_key},"
    puts "                u:         #{us[0][:expr]},"
    puts '                v:         v,'
    puts '                spec_id:   :eb_pocket_4mm'
    puts '        end'
  else
    entries.each_with_index do |e, i|
      puts "        screw '#{name_tpl} | #{i}',"
      puts "              host_name: '#{host}',"
      puts "              face:      :#{face_key},"
      puts "              u:         #{e[:u_snap][:expr]},"
      puts "              v:         #{e[:v_snap][:expr]},"
      puts '              spec_id:   :eb_pocket_4mm'
    end
  end

  puts '      end'
end

clusters.each { |(host, face_key), info| emit_cluster(host, face_key, info) }

unless already.empty?
  puts ''
  puts "[propose-screws] #{already.size} circle(s) already implemented — host was an EB | screw | … group. Snap the rebuild and draw fresh circles if you want changes."
end

skipped.each { |s| puts "[propose-screws] skipped: #{s}" }

puts ''
if clusters.empty? && already.any?
  puts '[propose-screws] nothing to propose (all circles already backed by screws).'
elsif clusters.empty?
  puts '[propose-screws] nothing to propose.'
end

'OK'
