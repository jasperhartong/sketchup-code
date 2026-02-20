# Dimensions.rb
# For wooden skeletons: select one component, run Dimensions.run
# - Horizontal: cumulative from top-left to the right side of each vertical beam (positioning).
# - Per-beam:   each child gets its own length dimension running alongside it.

Object.send(:remove_const, :Dimensions) if Object.const_defined?(:Dimensions)

module Dimensions
  extend self

  # Set to true to print debug info to the Ruby console (Window → Ruby Console).
  DEBUG = true

  # All length constants use .mm so they are correct in SketchUp's internal inches.

  # Gap between the beam geometry edge and the first cumulative dim line (below).
  OUTER_PADDING = 200.mm

  # How much further out each successive cumulative dim line is placed (stagger).
  STAGGER_STEP = 150.mm

  # How far alongside each beam its own length dimension is placed (outside the beam).
  # We add half the beam's thickness in that direction so the dimension line stays clear of the beam.
  BEAM_LENGTH_OFFSET = 80.mm

  # Minimum size in BOTH view axes for a top-level Group to receive a diagonal dimension.
  # Groups that are thin in one axis (beams, plates) are excluded.
  # Perpendicular offset applied to the outer diagonal dimension line so it sits clear of the geometry.
  DIAG_OFFSET = 100.mm

  # Tag folder that groups all dimension sublayers in the SketchUp tag panel.
  DIM_FOLDER = "maten"

  # Prefix applied to every dimension sublayer name (folder name + space).
  DIM_LAYER_PREFIX = "maten "

  # Positions within this distance are considered identical (deduplication only).
  DEDUP_EPSILON = 0.1.mm

  # Minimum distance to bother adding a dimension.
  MIN_DIMENSION_GAP = 1.mm

  # A beam must be at least this large in its longest projected axis to be
  # dimensioned. Filters out fasteners, connectors, and other tiny hardware
  # that live nested inside the same Groups as structural beams.
  MIN_BEAM_SPAN = 10.mm

  def debug(msg)
    return unless DEBUG
    puts "[Dimensions] #{msg}"
  end

  def run
    model = Sketchup.active_model
    sel   = model.selection
    inst  = selected_component_instance(sel)
    unless inst
      debug(selection_error_message(sel))
      return
    end

    view     = model.active_view
    cam      = view.camera
    view_dir = cam.direction.normalize
    view_h   = cam.xaxis.normalize   # horizontal right in current view
    view_v   = cam.yaxis.normalize   # vertical up in current view

    model.start_operation("Add Skeleton Dimensions", true)
    begin
      sublayer = find_or_create_maten_sublayer(model, inst)
      count = add_skeleton_dimensions(model, inst, view_dir, view_h, view_v, sublayer)
    ensure
      model.commit_operation
    end

    model.active_view.invalidate
    debug("Done. Added #{count} dimension(s).")
  end

  def clear
    model = Sketchup.active_model
    sel   = model.selection
    inst  = selected_component_instance(sel)
    unless inst
      debug(selection_error_message(sel))
      return
    end

    dims = model.entities.grep(Sketchup::DimensionLinear)
    return if dims.empty?

    model.start_operation("Clear Skeleton Dimensions", true)
    begin
      model.entities.erase_entities(dims)
    ensure
      model.commit_operation
    end

    model.active_view.invalidate
    debug("Cleared #{dims.size} dimension(s).")
  end

  # --- Algorithm ------------------------------------------------------------
  #
  # 1. Recursively collect all ComponentInstances at any nesting depth (Groups are
  #    transparent containers; each ComponentInstance is a beam). Accumulate
  #    the full world-space transformation at each level.
  # 2. Project each beam's bbox corners onto view_h / view_v.
  # 3. Find "top-left" origin = min-h, max-v across all beam corners.
  # 4. For vertical beams: push left- and right-edge x into far_x for cumulative dims.
  # 5. Sort + deduplicate far_x; emit one horizontal cumulative dim per unique x.
  # 6. Emit per-beam own-length dim alongside each beam (deduped by length+axis).
  #
  def add_skeleton_dimensions(model, inst, view_dir, view_h, view_v, sublayer = nil)
    parent_t = inst.transformation

    # Recursively collect all ComponentInstances at any depth, with their
    # accumulated world-space transformation. Groups are treated as transparent
    # containers and are not dimensioned themselves.
    beams = collect_beams_recursive(inst.definition.entities, parent_t)
    debug("beams found (all depths): #{beams.size}")
    return 0 if beams.empty?

    # All corners of structural beams in world space — used to derive the origin.
    # Filter out tiny hardware using the same MIN_BEAM_SPAN threshold so fasteners
    # don't distort the origin or the cumulative dim placement.
    structural_beams = beams.select { |child, world_t|
      corners = (0..7).map { |i| child.bounds.corner(i).transform(world_t) }
      hs = corners.map { |c| dot(c, view_h) }
      vs = corners.map { |c| dot(c, view_v) }
      [(hs.max - hs.min), (vs.max - vs.min)].max >= MIN_BEAM_SPAN
    }
    debug("structural beams (>= #{(MIN_BEAM_SPAN / 1.mm).round}mm span): #{structural_beams.size} of #{beams.size}")

    all_beam_corners = structural_beams.flat_map { |child, world_t|
      (0..7).map { |i| child.bounds.corner(i).transform(world_t) }
    }

    # Nudge anchor points toward the camera by the full component depth along view_dir,
    # so dimensions always render in front of the geometry regardless of component thickness.
    depth_projs = all_beam_corners.map { |c| dot(c, view_dir) }
    cam_depth   = depth_projs.max - depth_projs.min
    cam_nudge   = scale_vec(view_dir.reverse, cam_depth)
    nudge       = ->(pt) { Geom::Point3d.new(pt.x + cam_nudge.x, pt.y + cam_nudge.y, pt.z + cam_nudge.z) }
    debug("cam_depth=#{cam_depth.round(2)}, nudge=#{cam_nudge.to_s.strip}")

    # Origin = top-left of the beams' own extents (not the parent component bbox)
    origin_pt = all_beam_corners.min_by { |c| [dot(c, view_h), -dot(c, view_v)] }
    origin_x  = dot(origin_pt, view_h)
    origin_y  = dot(origin_pt, view_v)

    # Overall beam extents — used to place cumulative dim lines above/below the geometry
    beam_min_v = all_beam_corners.map { |c| dot(c, view_v) }.min
    beam_max_v = all_beam_corners.map { |c| dot(c, view_v) }.max

    # Vertical midpoint used to classify beams as "top-only" vs full-span/bottom.
    # A vertical beam whose bottom edge stays above mid_v is considered top-only and
    # its cumulative positioning dims are drawn above the structure instead of below.
    mid_v = (beam_max_v + beam_min_v) / 2.0

    debug("origin: #{origin_pt.to_s.strip}, h=#{origin_x.round(3)}, v=#{origin_y.round(3)}")
    debug("beam bottom_v=#{beam_min_v.round(3)}, beam_max_v=#{beam_max_v.round(3)}, mid_v=#{mid_v.round(3)}")

    # Vertical beams whose bottom edge stays above mid_v are "top-only"; their
    # cumulative x positions are drawn above the structure to reduce bottom clutter.
    far_x_top    = []   # [view_x, Point3d] — top-only vertical beams
    far_x_bottom = []   # [view_x, Point3d] — full-span / bottom vertical beams
    beam_lengths  = []  # [{start_pt, end_pt, offset, is_vertical}] — per-beam own-length dims

    structural_beams.each_with_index do |(child, world_t), idx|
      child_corners = (0..7).map { |i| child.bounds.corner(i).transform(world_t) }

      hs = child_corners.map { |c| dot(c, view_h) }
      vs = child_corners.map { |c| dot(c, view_v) }

      h_extent = hs.max - hs.min
      v_extent = vs.max - vs.min

      # Skip fasteners, connectors, and other tiny hardware
      if [h_extent, v_extent].max < MIN_BEAM_SPAN
        debug("child #{idx}: h=#{h_extent.round(2)} v=#{v_extent.round(2)} → SKIPPED (too small)")
        next
      end

      is_vertical = v_extent > h_extent   # taller than wide = perpendicular beam

      debug("child #{idx}: h=#{h_extent.round(2)} v=#{v_extent.round(2)} " \
            "→ #{is_vertical ? 'VERTICAL' : 'HORIZONTAL'}")

      # --- Cumulative horizontal positioning: left and right sides of vertical beams ---
      if is_vertical
        # A beam whose bottom edge stays above the vertical midpoint is "top-only".
        top_only   = vs.min > mid_v
        target_far = top_only ? far_x_top : far_x_bottom
        debug("  → cumulative bucket: #{top_only ? 'TOP' : 'BOTTOM'} (vs.min=#{vs.min.round(2)}, mid_v=#{mid_v.round(2)})")

        # Right (far) side — pick the corner at the NEAR edge of the structure:
        # bottom-right for below-dims, top-right for above-dims.
        # v_sign < 0 selects the topmost corner (top-only), > 0 the bottommost (below).
        v_sign   = top_only ? -1 : 1
        far_h_pt = child_corners.min_by { |c| [(dot(c, view_h) - hs.max).abs, v_sign * dot(c, view_v)] }
        target_far << [hs.max, far_h_pt]
      end

      # --- Per-beam own-length dimension alongside the beam (offset outside bbox) ---
      start_pt, end_pt, offset = beam_length_anchors(
        child_corners, hs, vs, h_extent, v_extent, is_vertical, view_h, view_v
      )
      if start_pt.distance(end_pt) >= MIN_DIMENSION_GAP
        beam_lengths << { start_pt: start_pt, end_pt: end_pt, offset: offset, is_vertical: is_vertical }
      end
    end

    unique_x_bottom = dedup_sorted(far_x_bottom.sort_by { |v, _| v })
    unique_x_top    = dedup_sorted(far_x_top.sort_by    { |v, _| v })
    debug("unique far-x BOTTOM: #{unique_x_bottom.map { |v, _| v.round(2) }}")
    debug("unique far-x TOP:    #{unique_x_top.map    { |v, _| v.round(2) }}")

    entities = model.entities
    count    = 0

    # Synthesize the far anchor point by stepping along view_h from a given base point,
    # keeping view_v and view_dir constant so SketchUp measures a pure horizontal distance.
    make_h_anchor = ->(base_pt, h_target) {
      h_diff = h_target - origin_x
      Geom::Point3d.new(
        base_pt.x + view_h.x * h_diff,
        base_pt.y + view_h.y * h_diff,
        base_pt.z + view_h.z * h_diff
      )
    }

    # Helper: build a base point at origin_x but at the v-level of a stored corner.
    # Both start and far anchors share the same v, so SketchUp measures a pure
    # horizontal distance and the extension lines run only OUTER_PADDING below/above
    # that specific beam's own edge.
    make_base_pt = ->(corner_pt) {
      v_diff = dot(corner_pt, view_v) - origin_y
      Geom::Point3d.new(
        origin_pt.x + view_v.x * v_diff,
        origin_pt.y + view_v.y * v_diff,
        origin_pt.z + view_v.z * v_diff
      )
    }

    # 1a. Cumulative horizontal dims BELOW the component (full-span / bottom beams)
    # gap_fn: how far this beam's bottom edge is above the overall bottom baseline (≥ 0),
    # so every dim line aligns at the same absolute staggered level.
    below_count = emit_cumulative_dims(
      entities, unique_x_bottom, origin_x,
      ->(pt) { dot(pt, view_v) - beam_min_v },
      view_v.reverse,
      make_base_pt: make_base_pt, make_h_anchor: make_h_anchor, nudge: nudge, sublayer: sublayer
    )
    count += below_count
    debug("cumulative horizontal dims BELOW: #{below_count}")

    # 1b. Cumulative horizontal dims ABOVE the component (top-only beams)
    # gap_fn: how far this beam's top edge is below the overall top baseline (≥ 0).
    above_count = emit_cumulative_dims(
      entities, unique_x_top, origin_x,
      ->(pt) { beam_max_v - dot(pt, view_v) },
      view_v,
      make_base_pt: make_base_pt, make_h_anchor: make_h_anchor, nudge: nudge, sublayer: sublayer
    )
    count += above_count
    debug("cumulative horizontal dims ABOVE: #{above_count}")

    # 2. Per-beam own-length dimension running alongside the beam (skip repeats on same axis)
    # Don't repeat beam length dimensions that have the same length AND start on the same axis.
    added_length_axis = {}  # (length_bucket, axis_bucket) -> true
    per_beam_count = 0
    beam_lengths.each do |entry|
      start_pt    = entry[:start_pt]
      end_pt      = entry[:end_pt]
      offset      = entry[:offset]
      is_vertical = entry[:is_vertical]
      length      = start_pt.distance(end_pt)
      # Axis = reference line the dimension starts from: same view_v = same horizontal line (vertical beams), same view_h = same vertical line (horizontal beams)
      axis_val      = is_vertical ? dot(start_pt, view_v) : dot(start_pt, view_h)
      length_bucket = (length / DEDUP_EPSILON).round * DEDUP_EPSILON
      axis_bucket   = (axis_val / DEDUP_EPSILON).round * DEDUP_EPSILON
      key = [length_bucket, axis_bucket]
      next if added_length_axis[key]
      added_length_axis[key] = true
      align_dim(entities.add_dimension_linear(nudge.call(start_pt), nudge.call(end_pt), offset), sublayer)
      count += 1
      per_beam_count += 1
    end
    debug("per-beam length dims added: #{per_beam_count} (from #{beam_lengths.size} beams, after same-length same-axis dedup)")

    # 3. Single outer diagonal — from the top-left to the bottom-right corner of
    #    the entire structure. Find the actual beam corner that is nearest (in view
    #    space) to each virtual bounding-box extreme: (min_h, max_v) and (max_h, min_v).
    beam_max_h = all_beam_corners.map { |c| dot(c, view_h) }.max
    tl = all_beam_corners.min_by { |c|
      (dot(c, view_h) - origin_x)**2 + (dot(c, view_v) - beam_max_v)**2
    }
    br = all_beam_corners.min_by { |c|
      (dot(c, view_h) - beam_max_h)**2 + (dot(c, view_v) - beam_min_v)**2
    }

    h_ext    = beam_max_h - origin_x
    v_ext    = beam_max_v - beam_min_v
    diag_len = Math.sqrt(h_ext**2 + v_ext**2)

    if diag_len >= MIN_DIMENSION_GAP
      # Offset perpendicular to the TL→BR diagonal, pointing upper-right in view space.
      # Diagonal direction (view_h, view_v): (+h_ext, -v_ext).
      # 90°-CCW perpendicular: (+v_ext, +h_ext) normalised.
      perp = Geom::Vector3d.new(
        view_h.x * (v_ext / diag_len) + view_v.x * (h_ext / diag_len),
        view_h.y * (v_ext / diag_len) + view_v.y * (h_ext / diag_len),
        view_h.z * (v_ext / diag_len) + view_v.z * (h_ext / diag_len)
      )
      offset = scale_vec(perp, DIAG_OFFSET)
      align_dim(entities.add_dimension_linear(nudge.call(tl), nudge.call(br), offset), sublayer)
      count += 1
      debug("outer diagonal: #{(h_ext * 25.4).round}x#{(v_ext * 25.4).round}mm → #{(diag_len * 25.4).round(1)}mm")
    end

    count
  end

  # Remove adjacent entries whose position values are within DEDUP_EPSILON.
  def dedup_sorted(sorted_pairs)
    out = []
    sorted_pairs.each do |v, pt|
      out << [v, pt] if out.empty? || (v - out.last[0]).abs > DEDUP_EPSILON
    end
    out
  end

  # Apply text-alignment settings and assign an optional layer to the dimension.
  def align_dim(dim, layer = nil)
    dim.has_aligned_text = true
    dim.aligned_text_position = Sketchup::DimensionLinear::ALIGNED_TEXT_ABOVE
    dim.layer = layer if layer
  end

  # Scale a Vector3d by a scalar (Vector3d * Float is cross product in SketchUp).
  def scale_vec(vec, scalar)
    Geom::Vector3d.new(vec.x * scalar, vec.y * scalar, vec.z * scalar)
  end

  # Dot product of a Point3d with a Vector3d axis (Point3d has no built-in .dot).
  def dot(pt, axis)
    pt.x * axis.x + pt.y * axis.y + pt.z * axis.z
  end

  # Recursively collect all ComponentInstances at any nesting depth under the
  # given entities collection. Groups are transparent containers — we step inside
  # them and accumulate the transformation, but do not add the Group itself as a
  # beam. ComponentInstances are leaf beams regardless of their nesting level.
  #
  # Returns an Array of [ComponentInstance, parent_transform] pairs where
  # parent_transform is the world-space transform of the entity's PARENT
  # coordinate system. Callers apply it to entity.bounds.corner(i) (which is
  # already in parent space) to obtain world-space corners.
  def collect_beams_recursive(entities, accumulated_t)
    result = []
    entities.each do |e|
      next unless e.respond_to?(:definition)
      # Transform from e's definition space → world (needed when recursing inside e)
      into_child_t = accumulated_t * e.transformation
      if e.is_a?(Sketchup::Group)
        # Groups are containers: recurse into their definition using into_child_t
        result.concat(collect_beams_recursive(e.definition.entities, into_child_t))
      else
        # ComponentInstance: e.bounds is already in parent space (accumulated_t's space).
        # Store accumulated_t so callers can do: e.bounds.corner(i).transform(accumulated_t)
        result << [e, accumulated_t]
      end
    end
    result
  end

  # Returns the name to use for the "maten" sublayer, based on the selected instance.
  # Priority: tag on the instance → instance name → definition name → persistent_id.
  def sublayer_name_for(inst)
    tag = inst.layer
    if tag && tag.name != "Layer0" && tag.name != "Untagged"
      return "#{DIM_LAYER_PREFIX}#{tag.name}"
    end
    iname = inst.name.to_s.strip
    return "#{DIM_LAYER_PREFIX}#{iname}" unless iname.empty?
    dname = inst.definition.name.to_s.strip
    return "#{DIM_LAYER_PREFIX}#{dname}" unless dname.empty?
    "#{DIM_LAYER_PREFIX}#{inst.persistent_id}"
  end

  # Finds or creates the DIM_FOLDER tag folder (SketchUp 2021+) and the named sublayer
  # inside it.  On older SketchUp (no folder support) the sublayer is created at root.
  def find_or_create_maten_sublayer(model, inst)
    sub_name = sublayer_name_for(inst)

    parent_folder = nil
    if model.layers.respond_to?(:add_folder)
      model.layers.folders.each { |f| parent_folder = f if f.name == DIM_FOLDER }
      parent_folder ||= model.layers.add_folder(DIM_FOLDER)
    end

    sub_layer = nil
    model.layers.each { |l| sub_layer = l if l.name == sub_name }
    unless sub_layer
      sub_layer = model.layers.add(sub_name)
      if parent_folder && sub_layer.respond_to?(:folder=)
        sub_layer.folder = parent_folder
      end
    end

    debug("Dimension sublayer: '#{sub_name}' (folder: '#{parent_folder ? parent_folder.name : 'none'}')")
    sub_layer
  end

  def selected_component_instance(selection)
    candidates = selection.grep(Sketchup::ComponentInstance)
    return nil unless candidates.length == 1
    candidates.first
  end

  def selection_error_message(selection)
    candidates = selection.grep(Sketchup::ComponentInstance)
    if selection.empty?
      "Nothing selected.\n\nSelect exactly one component instance, then run again."
    elsif candidates.empty?
      "Selection is not a component.\n\nSelect exactly one component instance (not a group or raw geometry), then run again."
    else
      "Too many components selected (#{candidates.length}).\n\nSelect exactly one component, then run again."
    end
  end

  # --- Private helpers ------------------------------------------------------

  # Emit one cumulative horizontal dimension per entry in unique_x_pairs.
  # gap_fn:      lambda(corner_pt) → non-negative gap from this beam's edge to the
  #              overall baseline, ensuring all dim lines align at a common staggered level.
  # stagger_dir: Vector3d direction to push successive dim lines further out.
  def emit_cumulative_dims(entities, unique_x_pairs, origin_x, gap_fn, stagger_dir,
                            make_base_pt:, make_h_anchor:, nudge:, sublayer: nil)
    dim_i = 0
    count = 0
    unique_x_pairs.each do |x, far_h_pt|
      next if (x - origin_x).abs < MIN_DIMENSION_GAP
      base_pt = make_base_pt.call(far_h_pt)
      far_pt  = make_h_anchor.call(base_pt, x)
      d       = gap_fn.call(far_h_pt) + OUTER_PADDING + dim_i * STAGGER_STEP
      off     = scale_vec(stagger_dir, d)
      align_dim(entities.add_dimension_linear(nudge.call(base_pt), nudge.call(far_pt), off), sublayer)
      count += 1
      dim_i  += 1
    end
    count
  end

  # Returns [start_pt, end_pt, offset_vec] for the per-beam own-length dimension.
  # Vertical beams: dim runs top→bottom along the left edge.
  # Horizontal beams: dim runs left→right along the top edge.
  def beam_length_anchors(child_corners, hs, vs, h_extent, v_extent, is_vertical, view_h, view_v)
    if is_vertical
      start_pt = child_corners.min_by { |c| [(dot(c, view_v) - vs.max).abs,  dot(c, view_h)] }
      end_pt   = child_corners.min_by { |c| [(dot(c, view_v) - vs.min).abs,  dot(c, view_h)] }
      offset   = scale_vec(view_h.reverse, h_extent * 0.5 + BEAM_LENGTH_OFFSET)
    else
      start_pt = child_corners.min_by { |c| [(dot(c, view_h) - hs.min).abs, -dot(c, view_v)] }
      end_pt   = child_corners.min_by { |c| [(dot(c, view_h) - hs.max).abs, -dot(c, view_v)] }
      offset   = scale_vec(view_v, v_extent * 0.5 + BEAM_LENGTH_OFFSET)
    end
    [start_pt, end_pt, offset]
  end

end

# To run: set view, select one component, then: Dimensions.run
