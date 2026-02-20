# core.rb — Skeleton Dimensions algorithm
#
# Single source of truth for the dimensioning logic. Used in two ways:
#
#   Plugin:  main.rb does `load core.rb` then `require ui.rb`
#   Dev:     command.rb does `load core.rb` directly, then calls:
#              Timmerman::SkeletonDimensions.debug_mode = true
#              Timmerman::SkeletonDimensions.clear
#              Timmerman::SkeletonDimensions.run
#
# Public API:
#   Timmerman::SkeletonDimensions.run               — add dimensions to the selected component
#   Timmerman::SkeletonDimensions.clear             — remove all linear dims from the model
#   Timmerman::SkeletonDimensions.debug_mode = bool — toggle console output (default: false)

require 'sketchup.rb'

module Timmerman
  module SkeletonDimensions
    extend self

    # Reload guard — remove algorithm constants before redefining them so that
    # `load`-ing this file a second time (during bridge iteration) always picks
    # up the latest values. The loader constants (PLUGIN_ID, PLUGIN_ROOT,
    # EXTENSION) live in the loader file and are intentionally left untouched.
    %i[
      OUTER_PADDING STAGGER_STEP BEAM_LENGTH_OFFSET DIAG_OFFSET
      DIM_FOLDER DIM_LAYER_PREFIX DEDUP_EPSILON MIN_DIMENSION_GAP MIN_BEAM_SPAN
    ].each { |c| remove_const(c) if const_defined?(c, false) }

    # Debug output is a module instance variable (not a constant) so it can be
    # toggled from command.rb without triggering a constant-redefinition warning.
    @debug = false
    def debug_mode=(val)
      @debug = val
    end

    # ---------------------------------------------------------------------------
    # Layout constants (all in SketchUp internal units; .mm converts mm → inches)
    # ---------------------------------------------------------------------------

    # Gap between the beam geometry edge and the first cumulative dim line.
    OUTER_PADDING = 200.mm

    # How much further out each successive cumulative dim line is placed (stagger).
    STAGGER_STEP = 150.mm

    # How far alongside a beam its own length dimension is placed (outside the beam).
    # Half the beam thickness in that direction is added on top so the line stays clear.
    BEAM_LENGTH_OFFSET = 80.mm

    # Perpendicular offset for the outer diagonal dimension line.
    DIAG_OFFSET = 100.mm

    # Tag folder that groups all dimension sub-layers in the SketchUp tag panel.
    DIM_FOLDER = 'maten'.freeze

    # Prefix applied to every dimension sub-layer name.
    DIM_LAYER_PREFIX = 'maten '.freeze

    # Positions within this distance are treated as identical during deduplication.
    DEDUP_EPSILON = 0.1.mm

    # Minimum distance to bother adding a dimension at all.
    MIN_DIMENSION_GAP = 1.mm

    # A beam must be at least this large in its longest projected axis to be
    # dimensioned — filters out fasteners, connectors, and other small hardware.
    MIN_BEAM_SPAN = 10.mm

    # ---------------------------------------------------------------------------
    # Public commands
    # ---------------------------------------------------------------------------

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
      view_h   = cam.xaxis.normalize
      view_v   = cam.yaxis.normalize

      model.start_operation('Add Skeleton Dimensions', true)
      begin
        sublayer = find_or_create_maten_sublayer(model, inst)
        count    = add_skeleton_dimensions(model, inst, view_dir, view_h, view_v, sublayer)
      rescue => e
        model.abort_operation
        UI.messagebox("Skeleton Dimensions failed:\n#{e.message}")
        return
      end
      model.commit_operation

      model.active_view.invalidate
      debug("Done. Added #{count} dimension(s).")
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
      if dims.empty?
        debug('No linear dimensions found to clear.')
        return
      end

      model.start_operation('Clear Skeleton Dimensions', true)
      begin
        model.entities.erase_entities(dims)
      rescue => e
        model.abort_operation
        UI.messagebox("Clear Dimensions failed:\n#{e.message}")
        return
      end
      model.commit_operation

      model.active_view.invalidate
      debug("Cleared #{dims.size} dimension(s).")
    end

    # ---------------------------------------------------------------------------
    # Core algorithm
    #
    # 1. Recursively collect all ComponentInstances at any nesting depth (Groups
    #    are transparent containers). Accumulate the full world-space transform.
    # 2. Project each beam's bbox corners onto view_h / view_v.
    # 3. Find "top-left" origin = min-h, max-v across all beam corners.
    # 4. For vertical beams: push the right-edge x into far_x for cumulative dims.
    # 5. Sort + deduplicate far_x; emit one horizontal cumulative dim per unique x.
    # 6. Emit per-beam own-length dim alongside each beam (deduped by length+axis).
    # ---------------------------------------------------------------------------

    def add_skeleton_dimensions(model, inst, view_dir, view_h, view_v, sublayer = nil)
      parent_t = inst.transformation
      beams    = collect_beams_recursive(inst.definition.entities, parent_t)
      debug("beams found (all depths): #{beams.size}")
      return 0 if beams.empty?

      structural_beams = beams.select { |child, world_t|
        corners = (0..7).map { |i| child.bounds.corner(i).transform(world_t) }
        hs = corners.map { |c| dot(c, view_h) }
        vs = corners.map { |c| dot(c, view_v) }
        [(hs.max - hs.min), (vs.max - vs.min)].max >= MIN_BEAM_SPAN
      }
      debug("structural beams (>= #{(MIN_BEAM_SPAN / 1.mm).round}mm span): " \
            "#{structural_beams.size} of #{beams.size}")

      all_beam_corners = structural_beams.flat_map { |child, world_t|
        (0..7).map { |i| child.bounds.corner(i).transform(world_t) }
      }

      # Nudge anchor points toward the camera by the full component depth so
      # dimensions always render in front of the geometry.
      depth_projs = all_beam_corners.map { |c| dot(c, view_dir) }
      cam_depth   = depth_projs.max - depth_projs.min
      cam_nudge   = scale_vec(view_dir.reverse, cam_depth)
      nudge = ->(pt) {
        Geom::Point3d.new(pt.x + cam_nudge.x, pt.y + cam_nudge.y, pt.z + cam_nudge.z)
      }

      origin_pt = all_beam_corners.min_by { |c| [dot(c, view_h), -dot(c, view_v)] }
      origin_x  = dot(origin_pt, view_h)
      origin_y  = dot(origin_pt, view_v)

      beam_min_v = all_beam_corners.map { |c| dot(c, view_v) }.min
      beam_max_v = all_beam_corners.map { |c| dot(c, view_v) }.max
      mid_v      = (beam_max_v + beam_min_v) / 2.0

      debug("origin: #{origin_pt.to_s.strip}, h=#{origin_x.round(3)}, v=#{origin_y.round(3)}")

      far_x_top    = []
      far_x_bottom = []
      beam_lengths  = []

      structural_beams.each_with_index do |(child, world_t), idx|
        child_corners = (0..7).map { |i| child.bounds.corner(i).transform(world_t) }

        hs = child_corners.map { |c| dot(c, view_h) }
        vs = child_corners.map { |c| dot(c, view_v) }

        h_extent = hs.max - hs.min
        v_extent = vs.max - vs.min

        next if [h_extent, v_extent].max < MIN_BEAM_SPAN

        is_vertical = v_extent > h_extent

        debug("child #{idx}: h=#{h_extent.round(2)} v=#{v_extent.round(2)} " \
              "-> #{is_vertical ? 'VERTICAL' : 'HORIZONTAL'}")

        if is_vertical
          top_only   = vs.min > mid_v
          target_far = top_only ? far_x_top : far_x_bottom
          v_sign     = top_only ? -1 : 1
          far_h_pt   = child_corners.min_by { |c|
            [(dot(c, view_h) - hs.max).abs, v_sign * dot(c, view_v)]
          }
          target_far << [hs.max, far_h_pt]
        end

        start_pt, end_pt, offset = beam_length_anchors(
          child_corners, hs, vs, h_extent, v_extent, is_vertical, view_h, view_v
        )
        if start_pt.distance(end_pt) >= MIN_DIMENSION_GAP
          beam_lengths << {
            start_pt: start_pt, end_pt: end_pt,
            offset: offset, is_vertical: is_vertical
          }
        end
      end

      unique_x_bottom = dedup_sorted(far_x_bottom.sort_by { |v, _| v })
      unique_x_top    = dedup_sorted(far_x_top.sort_by    { |v, _| v })

      entities = model.entities
      count    = 0

      make_h_anchor = ->(base_pt, h_target) {
        h_diff = h_target - origin_x
        Geom::Point3d.new(
          base_pt.x + view_h.x * h_diff,
          base_pt.y + view_h.y * h_diff,
          base_pt.z + view_h.z * h_diff
        )
      }

      make_base_pt = ->(corner_pt) {
        v_diff = dot(corner_pt, view_v) - origin_y
        Geom::Point3d.new(
          origin_pt.x + view_v.x * v_diff,
          origin_pt.y + view_v.y * v_diff,
          origin_pt.z + view_v.z * v_diff
        )
      }

      below_count = emit_cumulative_dims(
        entities, unique_x_bottom, origin_x,
        ->(pt) { dot(pt, view_v) - beam_min_v },
        view_v.reverse,
        make_base_pt: make_base_pt, make_h_anchor: make_h_anchor,
        nudge: nudge, sublayer: sublayer
      )
      count += below_count

      above_count = emit_cumulative_dims(
        entities, unique_x_top, origin_x,
        ->(pt) { beam_max_v - dot(pt, view_v) },
        view_v,
        make_base_pt: make_base_pt, make_h_anchor: make_h_anchor,
        nudge: nudge, sublayer: sublayer
      )
      count += above_count

      added_length_axis = {}
      beam_lengths.each do |entry|
        start_pt    = entry[:start_pt]
        end_pt      = entry[:end_pt]
        offset      = entry[:offset]
        is_vertical = entry[:is_vertical]
        length      = start_pt.distance(end_pt)
        axis_val    = is_vertical ? dot(start_pt, view_v) : dot(start_pt, view_h)
        length_bucket = (length   / DEDUP_EPSILON).round * DEDUP_EPSILON
        axis_bucket   = (axis_val / DEDUP_EPSILON).round * DEDUP_EPSILON
        key = [length_bucket, axis_bucket]
        next if added_length_axis[key]
        added_length_axis[key] = true
        align_dim(
          entities.add_dimension_linear(nudge.call(start_pt), nudge.call(end_pt), offset),
          sublayer
        )
        count += 1
      end

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
        perp = Geom::Vector3d.new(
          view_h.x * (v_ext / diag_len) + view_v.x * (h_ext / diag_len),
          view_h.y * (v_ext / diag_len) + view_v.y * (h_ext / diag_len),
          view_h.z * (v_ext / diag_len) + view_v.z * (h_ext / diag_len)
        )
        offset = scale_vec(perp, DIAG_OFFSET)
        align_dim(
          entities.add_dimension_linear(nudge.call(tl), nudge.call(br), offset),
          sublayer
        )
        count += 1
      end

      count
    end

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------

    def dedup_sorted(sorted_pairs)
      out = []
      sorted_pairs.each do |v, pt|
        out << [v, pt] if out.empty? || (v - out.last[0]).abs > DEDUP_EPSILON
      end
      out
    end

    def align_dim(dim, layer = nil)
      dim.has_aligned_text = true
      dim.aligned_text_position = Sketchup::DimensionLinear::ALIGNED_TEXT_ABOVE
      dim.layer = layer if layer
    end

    # Scale a Vector3d by a scalar (Vector3d * Float is cross product in SketchUp).
    def scale_vec(vec, scalar)
      Geom::Vector3d.new(vec.x * scalar, vec.y * scalar, vec.z * scalar)
    end

    # Dot product of a Point3d with a Vector3d axis.
    def dot(pt, axis)
      pt.x * axis.x + pt.y * axis.y + pt.z * axis.z
    end

    # Recursively collect all ComponentInstances at any nesting depth.
    # Groups are transparent containers — we step inside them and accumulate the
    # transformation, but do not add the Group itself as a beam.
    #
    # Returns Array of [ComponentInstance, parent_transform] pairs where
    # parent_transform is the world-space transform of the entity's *parent*
    # coordinate system. Callers apply it to entity.bounds.corner(i) (which is
    # already in parent space) to obtain world-space corners.
    def collect_beams_recursive(entities, accumulated_t)
      result = []
      entities.each do |e|
        next unless e.respond_to?(:definition)
        into_child_t = accumulated_t * e.transformation
        if e.is_a?(Sketchup::Group)
          result.concat(collect_beams_recursive(e.definition.entities, into_child_t))
        else
          result << [e, accumulated_t]
        end
      end
      result
    end

    def sublayer_name_for(inst)
      tag = inst.layer
      if tag && tag.name != 'Layer0' && tag.name != 'Untagged'
        return "#{DIM_LAYER_PREFIX}#{tag.name}"
      end
      iname = inst.name.to_s.strip
      return "#{DIM_LAYER_PREFIX}#{iname}" unless iname.empty?
      dname = inst.definition.name.to_s.strip
      return "#{DIM_LAYER_PREFIX}#{dname}" unless dname.empty?
      "#{DIM_LAYER_PREFIX}#{inst.persistent_id}"
    end

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

      debug("Dimension sublayer: '#{sub_name}' " \
            "(folder: '#{parent_folder ? parent_folder.name : 'none'}')")
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
        "Selection is not a component.\n\nSelect exactly one component instance " \
          "(not a group or raw geometry), then run again."
      else
        "Too many components selected (#{candidates.length}).\n\n" \
          "Select exactly one component, then run again."
      end
    end

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
        align_dim(
          entities.add_dimension_linear(nudge.call(base_pt), nudge.call(far_pt), off),
          sublayer
        )
        count += 1
        dim_i  += 1
      end
      count
    end

    def beam_length_anchors(child_corners, hs, vs, h_extent, v_extent,
                            is_vertical, view_h, view_v)
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

    def debug(msg)
      return unless @debug
      puts "[SkeletonDimensions] #{msg}"
    end

  end
end
