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

  def debug(msg)
    return unless DEBUG
    puts "[Dimensions] #{msg}"
  end

  def run
    model = Sketchup.active_model
    sel   = model.selection
    inst  = selected_component_instance(sel)
    unless inst
      UI.messagebox(selection_error_message(sel))
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
    UI.messagebox("Added #{count} dimension(s) from top-left (cumulative).")
  end

  def clear
    model = Sketchup.active_model
    sel   = model.selection
    inst  = selected_component_instance(sel)
    unless inst
      UI.messagebox(selection_error_message(sel))
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
    UI.messagebox("Cleared #{dims.size} dimension(s).")
  end

  # --- Algorithm ------------------------------------------------------------
  #
  # 1. Get the 8 corners of the top component bbox → find the "top-left" origin
  #    (min horizontal, max vertical in the current view).
  # 2. Iterate direct child components/groups — each is a beam.
  # 3. For each beam, compute its bounding box in world space (8 corners).
  # 4. Project each bbox onto view_h / view_v → far_x = max right, far_y = min bottom.
  # 5. Sort those far-side positions, deduplicate identical ones.
  # 6. For each unique far-side position add one dimension from origin.
  #
  def add_skeleton_dimensions(model, inst, view_dir, view_h, view_v)
    parent_t = inst.transformation

    # Projection: 3D point → scalar along a view axis (Point3d has no .dot)
    proj = ->(pt, axis) { pt.x * axis.x + pt.y * axis.y + pt.z * axis.z }

    # Collect direct children (beams) up front so we can derive the origin from them
    children = inst.definition.entities.select { |e| e.respond_to?(:definition) }
    debug("direct child components/groups: #{children.size}")
    return 0 if children.empty?

    # All corners of all children in world space — this is the actual beam geometry
    all_beam_corners = children.flat_map { |child|
      (0..7).map { |i| child.bounds.corner(i).transform(parent_t) }
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

    # Overall beam extents — used to place cumulative dim lines below the geometry
    beam_min_v = all_beam_corners.map { |c| proj.call(c, view_v) }.min

    # Base offset for horizontal cumulative dims: below the bottom of all beams
    base_offset_h = (origin_y - beam_min_v) + OUTER_PADDING

    debug("origin: #{origin_pt.to_s.strip}, h=#{origin_x.round(3)}, v=#{origin_y.round(3)}")
    debug("beam bottom_v=#{beam_min_v.round(3)}, base_offset_h=#{base_offset_h.round(3)}")

    far_x        = []   # [view_x, Point3d] — for cumulative horizontal positioning dims
    beam_lengths  = []  # [[start_pt, end_pt, offset_vec]] — per-beam own-length dims

    children.each_with_index do |child, idx|
      child_corners = (0..7).map { |i| child.bounds.corner(i).transform(parent_t) }

      hs = child_corners.map { |c| proj.call(c, view_h) }
      vs = child_corners.map { |c| proj.call(c, view_v) }

      h_extent = hs.max - hs.min
      v_extent = vs.max - vs.min
      is_vertical = v_extent > h_extent   # taller than wide = perpendicular beam

      debug("child #{idx}: h=#{h_extent.round(2)} v=#{v_extent.round(2)} " \
            "→ #{is_vertical ? 'VERTICAL' : 'HORIZONTAL'}")

      # --- Cumulative horizontal positioning: right side of vertical beams only ---
      if is_vertical
        far_h_pt = child_corners.min_by { |c|
          [(proj.call(c, view_h) - hs.max).abs, proj.call(c, view_v)]
        }
        far_x << [hs.max, far_h_pt]
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

      beam_lengths << [start_pt, end_pt, offset] if start_pt.distance(end_pt) >= MIN_DIMENSION_GAP
    end

    unique_x = dedup_sorted(far_x.sort_by { |v, _| v })
    debug("unique far-x positions: #{unique_x.map { |v, _| v.round(2) }}")

    entities = model.entities
    count    = 0
    dim_i    = 0

    # 1. Cumulative horizontal dims below the component (position of each vertical beam)
    unique_x.each do |x, pt|
      next if (x - origin_x).abs < MIN_DIMENSION_GAP
      next if origin_pt.distance(pt) < MIN_DIMENSION_GAP
      d   = base_offset_h + dim_i * STAGGER_STEP
      off = scale_vec(view_v.reverse, d)
      align_dim(entities.add_dimension_linear(nudge.call(origin_pt), nudge.call(pt), off))
      count += 1
      dim_i += 1
    end
    debug("cumulative horizontal dims added: #{count}")

    # 2. Per-beam own-length dimension running alongside the beam itself
    beam_lengths.each do |start_pt, end_pt, offset|
      align_dim(entities.add_dimension_linear(nudge.call(start_pt), nudge.call(end_pt), offset))
      count += 1
    end
    debug("per-beam length dims added: #{beam_lengths.size}")

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
