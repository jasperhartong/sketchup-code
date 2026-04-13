# frozen_string_literal: true

# Geometry snapshot and diff utility for extendable-bed.rb.
#
# Captures the world-space bounding box of every named part group in the model,
# keyed by its full Outliner path.  Useful for verifying that a refactor or
# geometry change produces an identical (or intentionally different) result.
#
# Typical workflow:
#
#   # 1. Run the bed, save a baseline snapshot.
#   load File.expand_path('extendable-bed.rb', __dir__)
#   Timmerman::ExtendableBed.create
#   EBCompare.save_snapshot('/tmp/snap_before.json')
#
#   # 2. Make your changes, re-run, save a new snapshot.
#   load File.expand_path('extendable-bed.rb', __dir__)
#   Timmerman::ExtendableBed.create
#   EBCompare.save_snapshot('/tmp/snap_after.json')
#
#   # 3. Diff them (can be done outside SketchUp).
#   issues = EBCompare.diff_files('/tmp/snap_before.json', '/tmp/snap_after.json')
#   puts issues.empty? ? 'PASS' : issues.join("\n")

module EBCompare
  # ── Snapshot ──────────────────────────────────────────────────────────────

  # Walks all groups in the model, records every leaf group's world-space
  # bounding box (min/max corners in mm, rounded to 3 dp).
  # Returns Hash { "RootName / PartName" => { min: [x,y,z], max: [x,y,z] } }
  def self.snapshot(model = Sketchup.active_model)
    result = {}
    model.entities.grep(Sketchup::Group).each do |root|
      next unless root.valid?
      _walk(root.entities, root.transformation, [root.name], result)
    end
    result
  end

  def self.save_snapshot(path, model = Sketchup.active_model)
    require 'json'
    snap = snapshot(model)
    File.write(path, JSON.pretty_generate(snap))
    puts "[EBCompare] Snapshot written: #{snap.size} parts → #{path}"
    snap
  end

  # ── Diff ──────────────────────────────────────────────────────────────────

  # Compares two snapshots (Hashes or JSON file paths).
  # Returns an array of human-readable issue strings (empty = identical).
  def self.diff(snap_a, snap_b, label_a: 'A', label_b: 'B')
    all_keys = (snap_a.keys + snap_b.keys).uniq.sort
    issues   = []
    all_keys.each do |key|
      a = snap_a[key]
      b = snap_b[key]
      if    a.nil? then issues << "  [ADDED in #{label_b}]  #{key}"
      elsif b.nil? then issues << "  [MISSING in #{label_b}]  #{key}"
      elsif a[:min] != b[:min] || a[:max] != b[:max]
        issues << "  [MISMATCH]  #{key}"
        issues << "    #{label_a}: min=#{a[:min].inspect}  max=#{a[:max].inspect}"
        issues << "    #{label_b}: min=#{b[:min].inspect}  max=#{b[:max].inspect}"
      end
    end
    issues
  end

  def self.diff_files(path_a, path_b, label_a: 'A', label_b: 'B')
    require 'json'
    parse = ->(p) { JSON.parse(File.read(p)).transform_keys(&:to_s).transform_values { |v| { min: v['min'], max: v['max'] } } }
    diff(parse.call(path_a), parse.call(path_b), label_a: label_a, label_b: label_b)
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  def self._walk(entities, world_tr, path, result)
    child_groups = entities.grep(Sketchup::Group).select(&:valid?)
    if child_groups.empty?
      min_pt, max_pt = _world_bb(entities, world_tr)
      result[path.join(' / ')] = { min: _mm3(min_pt), max: _mm3(max_pt) }
      return
    end
    child_groups.each { |g| _walk(g.entities, world_tr * g.transformation, path + [g.name], result) }
  end

  def self._world_bb(entities, world_tr)
    xs = []; ys = []; zs = []
    entities.grep(Sketchup::Face).each do |face|
      face.vertices.each do |v|
        wp = v.position.transform(world_tr)
        xs << wp.x; ys << wp.y; zs << wp.z
      end
    end
    return [Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(0, 0, 0)] if xs.empty?
    [Geom::Point3d.new(xs.min, ys.min, zs.min), Geom::Point3d.new(xs.max, ys.max, zs.max)]
  end

  def self._mm3(pt) = [pt.x.to_mm.round(3), pt.y.to_mm.round(3), pt.z.to_mm.round(3)]
end
