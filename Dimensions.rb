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
      count = add_skeleton_dimensions(model, inst, view_dir, view_h, view_v)
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
  def add_skeleton_dimensions(model, inst, view_dir, view_h, view_v)
    parent_t = inst.transformation

    # Projection: 3D point → scalar along a view axis (Point3d has no .dot)
    proj = ->(pt, axis) { pt.x * axis.x + pt.y * axis.y + pt.z * axis.z }

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
      hs = corners.map { |c| proj.call(c, view_h) }
      vs = corners.map { |c| proj.call(c, view_v) }
      [(hs.max - hs.min), (vs.max - vs.min)].max >= MIN_BEAM_SPAN
    }
    debug("structural beams (>= #{(MIN_BEAM_SPAN / 1.mm).round}mm span): #{structural_beams.size} of #{beams.size}")

    all_beam_corners = structural_beams.flat_map { |child, world_t|
      (0..7).map { |i| child.bounds.corner(i).transform(world_t) }
    }

    # Nudge anchor points toward the camera by the full component depth along view_dir,
    # so dimensions always render in front of the geometry regardless of component thickness.
    depth_projs = all_beam_corners.map { |c| proj.call(c, view_dir) }
    cam_depth   = depth_projs.max - depth_projs.min
    cam_nudge   = scale_vec(view_dir.reverse, cam_depth)
    nudge       = ->(pt) { Geom::Point3d.new(pt.x + cam_nudge.x, pt.y + cam_nudge.y, pt.z + cam_nudge.z) }
    debug("cam_depth=#{cam_depth.round(2)}, nudge=#{cam_nudge.to_s.strip}")

    # Origin = top-left of the beams' own extents (not the parent component bbox)
    origin_pt = all_beam_corners.min_by { |c| [proj.call(c, view_h), -proj.call(c, view_v)] }
    origin_x  = proj.call(origin_pt, view_h)
    origin_y  = proj.call(origin_pt, view_v)

    # Overall beam extents — used to place cumulative dim lines above/below the geometry
    beam_min_v = all_beam_corners.map { |c| proj.call(c, view_v) }.min
    beam_max_v = all_beam_corners.map { |c| proj.call(c, view_v) }.max

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
    beam_lengths  = []  # [[start_pt, end_pt, offset_vec]] — per-beam own-length dims

    structural_beams.each_with_index do |(child, world_t), idx|
      child_corners = (0..7).map { |i| child.bounds.corner(i).transform(world_t) }

      hs = child_corners.map { |c| proj.call(c, view_h) }
      vs = child_corners.map { |c| proj.call(c, view_v) }

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
        # That way each dim's extension line stops at the beam's own edge.
        if top_only
          far_h_pt = child_corners.min_by { |c|
            [(proj.call(c, view_h) - hs.max).abs, -proj.call(c, view_v)]
          }
        else
          far_h_pt = child_corners.min_by { |c|
            [(proj.call(c, view_h) - hs.max).abs, proj.call(c, view_v)]
          }
        end
        target_far << [hs.max, far_h_pt]
      end

      # --- Per-beam own-length dimension alongside the beam (offset outside bbox) ---
      if is_vertical
        # Dimension runs top→bottom along the left edge of the beam
        start_pt = child_corners.min_by { |c| [(proj.call(c, view_v) - vs.max).abs,  proj.call(c, view_h)] }
        end_pt   = child_corners.min_by { |c| [(proj.call(c, view_v) - vs.min).abs,  proj.call(c, view_h)] }
        # Offset = half beam width + padding so dimension line sits clearly outside the beam
        half_width = (h_extent * 0.5)
        offset   = scale_vec(view_h.reverse, half_width + BEAM_LENGTH_OFFSET)
      else
        # Dimension runs left→right along the top edge of the beam
        start_pt = child_corners.min_by { |c| [(proj.call(c, view_h) - hs.min).abs, -proj.call(c, view_v)] }
        end_pt   = child_corners.min_by { |c| [(proj.call(c, view_h) - hs.max).abs, -proj.call(c, view_v)] }
        half_depth = (v_extent * 0.5)
        offset   = scale_vec(view_v, half_depth + BEAM_LENGTH_OFFSET)
      end

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
      v_diff = proj.call(corner_pt, view_v) - origin_y
      Geom::Point3d.new(
        origin_pt.x + view_v.x * v_diff,
        origin_pt.y + view_v.y * v_diff,
        origin_pt.z + view_v.z * v_diff
      )
    }

    # 1a. Cumulative horizontal dims BELOW the component (full-span / bottom beams)
    # The offset is measured from the anchor (beam's own bottom edge) and must reach
    # the same staggered absolute level for every dim. The extra gap from this beam's
    # bottom down to beam_min_v is added so all dim lines align at a common baseline.
    dim_i = 0
    unique_x_bottom.each do |x, far_h_pt|
      next if (x - origin_x).abs < MIN_DIMENSION_GAP
      base_pt    = make_base_pt.call(far_h_pt)   # at this beam's bottom-v
      far_pt     = make_h_anchor.call(base_pt, x)
      gap_to_baseline = proj.call(far_h_pt, view_v) - beam_min_v  # ≥ 0: beam bottom is above overall baseline
      d   = gap_to_baseline + OUTER_PADDING + dim_i * STAGGER_STEP
      off = scale_vec(view_v.reverse, d)
      align_dim(entities.add_dimension_linear(nudge.call(base_pt), nudge.call(far_pt), off))
      count += 1
      dim_i += 1
    end
    debug("cumulative horizontal dims BELOW: #{dim_i}")

    # 1b. Cumulative horizontal dims ABOVE the component (top-only beams)
    dim_j = 0
    unique_x_top.each do |x, far_h_pt|
      next if (x - origin_x).abs < MIN_DIMENSION_GAP
      base_pt    = make_base_pt.call(far_h_pt)   # at this beam's top-v
      far_pt     = make_h_anchor.call(base_pt, x)
      gap_to_baseline = beam_max_v - proj.call(far_h_pt, view_v)  # ≥ 0: beam top is below overall baseline
      d   = gap_to_baseline + OUTER_PADDING + dim_j * STAGGER_STEP
      off = scale_vec(view_v, d)
      align_dim(entities.add_dimension_linear(nudge.call(base_pt), nudge.call(far_pt), off))
      count += 1
      dim_j += 1
    end
    debug("cumulative horizontal dims ABOVE: #{dim_j}")

    # 2. Per-beam own-length dimension running alongside the beam (skip repeats on same axis)
    # Don't repeat beam length dimensions that have the same length AND start on the same axis.
    added_length_axis = {}  # (length_bucket, axis_bucket) -> true
    per_beam_count = 0
    beam_lengths.each do |entry|
      start_pt   = entry[:start_pt]
      end_pt     = entry[:end_pt]
      offset     = entry[:offset]
      is_vertical = entry[:is_vertical]
      length     = start_pt.distance(end_pt)
      # Axis = reference line the dimension starts from: same view_v = same horizontal line (vertical beams), same view_h = same vertical line (horizontal beams)
      axis_val   = is_vertical ? proj.call(start_pt, view_v) : proj.call(start_pt, view_h)
      length_bucket = (length / DEDUP_EPSILON).round * DEDUP_EPSILON
      axis_bucket  = (axis_val / DEDUP_EPSILON).round * DEDUP_EPSILON
      key = [length_bucket, axis_bucket]
      next if added_length_axis[key]
      added_length_axis[key] = true
      align_dim(entities.add_dimension_linear(nudge.call(start_pt), nudge.call(end_pt), offset))
      count += 1
      per_beam_count += 1
    end
    debug("per-beam length dims added: #{per_beam_count} (from #{beam_lengths.size} beams, after same-length same-axis dedup)")

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

  # Apply text-alignment settings so the label is parallel to the dimension line.
  def align_dim(dim)
    dim.has_aligned_text = true
    dim.aligned_text_position = Sketchup::DimensionLinear::ALIGNED_TEXT_ABOVE
  end

  # Scale a Vector3d by a scalar (Vector3d * Float is cross product in SketchUp).
  def scale_vec(vec, scalar)
    Geom::Vector3d.new(vec.x * scalar, vec.y * scalar, vec.z * scalar)
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
end

# To run: set view, select one component, then: Dimensions.run
