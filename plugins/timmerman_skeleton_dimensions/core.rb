# encoding: utf-8
# core.rb - Skeleton Dimensions algorithm
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
#   Timmerman::SkeletonDimensions.run               - add dimensions to the selected component
#   Timmerman::SkeletonDimensions.clear             - remove all linear dims from the model
#   Timmerman::SkeletonDimensions.debug_mode = bool - toggle console output (default: false)

require 'sketchup.rb'

module Timmerman
  module SkeletonDimensions
    extend self

    # Reload guard - remove algorithm constants before redefining them so that
    # `load`-ing this file a second time (during bridge iteration) always picks
    # up the latest values. The loader constants (PLUGIN_ID, PLUGIN_ROOT,
    # EXTENSION) live in the loader file and are intentionally left untouched.
    %i[
      OUTER_PADDING STAGGER_STEP BEAM_LENGTH_OFFSET DIAG_OFFSET
      DIM_FOLDER DIM_LAYER_PREFIX DEDUP_EPSILON MIN_DIMENSION_GAP MIN_BEAM_SPAN
      AXIS_ALIGN_TOL
    ].each { |c| remove_const(c) if const_defined?(c, false) }

    # Debug output is a module instance variable (not a constant) so it can be
    # toggled from command.rb without triggering a constant-redefinition warning.
    @debug = false
    def debug_mode=(val)
      @debug = val
    end

    # ---------------------------------------------------------------------------
    # Layout constants (all in SketchUp internal units; .mm converts mm to inches)
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
    # dimensioned - filters out fasteners, connectors, and other small hardware.
    MIN_BEAM_SPAN = 10.mm

    # Maximum allowed misalignment between a component's local axis and a view
    # axis for the component to be considered axis-aligned. cos(angle) must
    # exceed 1 - AXIS_ALIGN_TOL, which corresponds to ~2.6° at 0.001.
    # This is used to classify beams as :vertical, :horizontal, or :diagonal
    # without a fuzzy aspect-ratio threshold.
    AXIS_ALIGN_TOL = 0.001

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

      sublayer = find_or_create_maten_sublayer(model, inst)
      dims     = model.entities.grep(Sketchup::DimensionLinear).select { |d| d.layer == sublayer }
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
    # 3. Classify each beam as :vertical, :horizontal, or :diagonal.
    # 4. For :vertical beams: push the right-edge x into far_x for cumulative dims.
    # 5. Sort + deduplicate far_x; emit one horizontal cumulative dim per unique x.
    # 6. Emit per-beam own-length dim alongside each beam.
    #    :vertical/:horizontal beams are deduped by (axis, length, position).
    #    :diagonal beams are never deduped - each one always gets its own dimension.
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

        beam_axis = classify_beam(child, world_t, h_extent, v_extent, view_h, view_v, view_dir)

        label = beam_axis == :diagonal ? "/ DIAGONAL" : beam_axis.upcase
        debug("child #{idx}: h=#{(h_extent*25.4).round(1)}mm v=#{(v_extent*25.4).round(1)}mm " \
              "-> #{label}")

        if beam_axis == :vertical
          top_only   = vs.min > mid_v
          target_far = top_only ? far_x_top : far_x_bottom
          v_sign     = top_only ? -1 : 1
          far_h_pt   = child_corners.min_by { |c|
            [(dot(c, view_h) - hs.max).abs, v_sign * dot(c, view_v)]
          }
          target_far << [hs.max, far_h_pt]
        end

        start_pt, end_pt, offset = beam_length_anchors(
          child, world_t, child_corners, hs, vs, h_extent, v_extent, beam_axis, view_h, view_v
        )
        if start_pt.distance(end_pt) >= MIN_DIMENSION_GAP
          beam_lengths << {
            start_pt: start_pt, end_pt: end_pt,
            offset: offset, beam_axis: beam_axis
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

      # Emit per-beam length dimensions.
      # :vertical/:horizontal: dedup by (type, length, position on dominant axis).
      # :diagonal: dedup by (start-pos, end-pos) so each unique beam gets one dim but
      #            exact position duplicates (e.g. instanced components) are suppressed.
      added_length_axis = {}
      beam_lengths.each do |entry|
        start_pt  = entry[:start_pt]
        end_pt    = entry[:end_pt]
        offset    = entry[:offset]
        beam_axis = entry[:beam_axis]
        length    = start_pt.distance(end_pt)

        key = case beam_axis
        when :vertical
          [:v, (length / DEDUP_EPSILON).round,
               (dot(start_pt, view_v) / DEDUP_EPSILON).round]
        when :horizontal
          [:h, (length / DEDUP_EPSILON).round,
               (dot(start_pt, view_h) / DEDUP_EPSILON).round]
        else # :diagonal - normalize endpoint order so A->B and B->A share one key
          sh = (dot(start_pt, view_h) / DEDUP_EPSILON).round
          sv = (dot(start_pt, view_v) / DEDUP_EPSILON).round
          eh = (dot(end_pt,   view_h) / DEDUP_EPSILON).round
          ev = (dot(end_pt,   view_v) / DEDUP_EPSILON).round
          [:d, *[[sh, sv], [eh, ev]].sort.flatten]
        end

        next if added_length_axis[key]
        added_length_axis[key] = true

        align_dim(
          entities.add_dimension_linear(nudge.call(start_pt), nudge.call(end_pt), offset),
          sublayer
        )
        count += 1
      end

      beam_max_h = all_beam_corners.map { |c| dot(c, view_h) }.max
      # Overall diagonals use coplanar anchors so the dimension shows the true
      # view-plane diagonal, not the 3D distance between corners at different depths.
      front_depth = all_beam_corners.map { |c| dot(c, view_dir) }.min
      depth_off   = front_depth - dot(origin_pt, view_dir)
      tl = Geom::Point3d.new(
        origin_pt.x + view_v.x * (beam_max_v - origin_y) + view_dir.x * depth_off,
        origin_pt.y + view_v.y * (beam_max_v - origin_y) + view_dir.y * depth_off,
        origin_pt.z + view_v.z * (beam_max_v - origin_y) + view_dir.z * depth_off
      )
      br = Geom::Point3d.new(
        origin_pt.x + view_h.x * (beam_max_h - origin_x) + view_v.x * (beam_min_v - origin_y) + view_dir.x * depth_off,
        origin_pt.y + view_h.y * (beam_max_h - origin_x) + view_v.y * (beam_min_v - origin_y) + view_dir.y * depth_off,
        origin_pt.z + view_h.z * (beam_max_h - origin_x) + view_v.z * (beam_min_v - origin_y) + view_dir.z * depth_off
      )

      tl_br_len = tl.distance(br)
      if tl_br_len >= MIN_DIMENSION_GAP
        # TL to BR overall diagonal. Perpendicular computed from the actual segment
        # direction (not bounding-box extents) so the offset is exactly 90 deg to the line.
        tb_dh = dot(br, view_h) - dot(tl, view_h)
        tb_dv = dot(br, view_v) - dot(tl, view_v)
        tb_2d = Math.sqrt(tb_dh**2 + tb_dv**2)
        # CCW 90 deg of (tb_dh, tb_dv) points "above" the down-right line (up-right)
        perp_tr = Geom::Vector3d.new(
          (-view_h.x * tb_dv + view_v.x * tb_dh) / tb_2d,
          (-view_h.y * tb_dv + view_v.y * tb_dh) / tb_2d,
          (-view_h.z * tb_dv + view_v.z * tb_dh) / tb_2d
        )
        align_dim(
          entities.add_dimension_linear(nudge.call(tl), nudge.call(br), scale_vec(perp_tr, DIAG_OFFSET)),
          sublayer,
          prefix: "◩ "
        )
        count += 1

        # BL to TR overall diagonal. Same plane as TL-BR.
        bl = Geom::Point3d.new(
          origin_pt.x + view_v.x * (beam_min_v - origin_y) + view_dir.x * depth_off,
          origin_pt.y + view_v.y * (beam_min_v - origin_y) + view_dir.y * depth_off,
          origin_pt.z + view_v.z * (beam_min_v - origin_y) + view_dir.z * depth_off
        )
        tr = Geom::Point3d.new(
          origin_pt.x + view_h.x * (beam_max_h - origin_x) + view_v.x * (beam_max_v - origin_y) + view_dir.x * depth_off,
          origin_pt.y + view_h.y * (beam_max_h - origin_x) + view_v.y * (beam_max_v - origin_y) + view_dir.y * depth_off,
          origin_pt.z + view_h.z * (beam_max_h - origin_x) + view_v.z * (beam_max_v - origin_y) + view_dir.z * depth_off
        )
        bt_2d = bl.distance(tr)
        if bt_2d >= MIN_DIMENSION_GAP
          bt_dh = dot(tr, view_h) - dot(bl, view_h)
          bt_dv = dot(tr, view_v) - dot(bl, view_v)
          # CCW 90 deg of (bt_dh, bt_dv) points "above" the up-right line (up-left)
          perp_tl = Geom::Vector3d.new(
            (-view_h.x * bt_dv + view_v.x * bt_dh) / bt_2d,
            (-view_h.y * bt_dv + view_v.y * bt_dh) / bt_2d,
            (-view_h.z * bt_dv + view_v.z * bt_dh) / bt_2d
          )
          align_dim(
            entities.add_dimension_linear(nudge.call(bl), nudge.call(tr), scale_vec(perp_tl, DIAG_OFFSET)),
            sublayer,
            prefix: "◩ "
          )
          count += 1
        end
      end

      count
    end

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------

    # Classify a beam into one of three categories by inspecting its actual
    # local axes in view space — no fuzzy aspect-ratio threshold needed.
    #
    # A beam is axis-aligned (:vertical or :horizontal) if every one of its
    # three local axes is parallel (within AXIS_ALIGN_TOL) to view_h, view_v,
    # or view_dir. A rafter or brace will have at least one local axis that is
    # diagonal in the view plane, so it falls through to :diagonal.
    #
    # Note: world_t is the *parent* accumulated transform; e.transformation is
    # the entity's own transform. The full world-space transform is their product.
    def classify_beam(e, world_t, h_extent, v_extent, view_h, view_v, view_dir)
      full_t  = world_t * e.transformation
      aligned = [full_t.xaxis, full_t.yaxis, full_t.zaxis].all? { |ax|
        n = ax.normalize
        [view_h, view_v, view_dir].any? { |ref| n.dot(ref).abs > 1.0 - AXIS_ALIGN_TOL }
      }
      return :diagonal unless aligned
      h_extent >= v_extent ? :horizontal : :vertical
    end

    # Compute the principal direction of a beam projected onto the view plane.
    #
    # Runs 2D PCA on the 8 projected bbox corners (already projected as hs/vs arrays)
    # and returns [uh, uv]: a unit vector in view space pointing along the longest
    # axis of the projected shape. For a 38x38x2400mm rafter at any angle this gives
    # the direction of the 2400mm axis, not the 38mm cross-section.
    def beam_principal_direction_2d(hs, vs)
      n   = hs.size.to_f
      mh  = hs.sum / n
      mv  = vs.sum / n
      chh = hs.sum { |h| (h - mh)**2 } / n
      cvv = vs.sum { |v| (v - mv)**2 } / n
      chv = hs.zip(vs).sum { |h, v| (h - mh) * (v - mv) } / n
      tr  = chh + cvv
      di  = Math.sqrt([(tr * 0.5)**2 - (chh * cvv - chv**2), 0.0].max)
      l1  = tr * 0.5 + di
      if chv.abs > 1.0e-12
        uh, uv = l1 - cvv, chv
      elsif chh >= cvv
        uh, uv = 1.0, 0.0
      else
        uh, uv = 0.0, 1.0
      end
      len = Math.sqrt(uh**2 + uv**2)
      len < 1.0e-12 ? [1.0, 0.0] : [uh / len, uv / len]
    end

    def dedup_sorted(sorted_pairs)
      out = []
      sorted_pairs.each do |v, pt|
        out << [v, pt] if out.empty? || (v - out.last[0]).abs > DEDUP_EPSILON
      end
      out
    end

    def align_dim(dim, layer = nil, prefix: nil)
      dim.has_aligned_text = true
      dim.aligned_text_position = Sketchup::DimensionLinear::ALIGNED_TEXT_ABOVE
      dim.layer = layer if layer
      dim.text = "#{prefix}<>" if prefix
    end

    # Scale a Vector3d by a scalar (Vector3d * Float is cross product in SketchUp).
    def scale_vec(vec, scalar)
      Geom::Vector3d.new(vec.x * scalar, vec.y * scalar, vec.z * scalar)
    end

    # Dot product of a Point3d with a Vector3d axis.
    def dot(pt, axis)
      pt.x * axis.x + pt.y * axis.y + pt.z * axis.z
    end

    # Recursively collect all leaf entities (beams) at any nesting depth.
    #
    # An entity is a *container* if its definition contains nested Groups or
    # ComponentInstances - we recurse into it without adding it as a beam.
    # An entity is a *leaf* if its definition contains only raw geometry -
    # we add it as a beam regardless of whether it is a Group or ComponentInstance.
    # This handles both layouts:
    #   * Flat: ComponentInstances with raw geometry (typical SketchUp components)
    #   * Nested: Groups/Components wrapping sub-components as containers
    #   * Mixed: Groups containing raw geometry alongside ComponentInstances
    #
    # Returns Array of [entity, parent_transform] pairs. Callers apply
    # parent_transform to entity.bounds.corner(i) (already in parent space) to
    # obtain world-space corners.
    def collect_beams_recursive(entities, accumulated_t)
      result = []
      entities.each do |e|
        next unless e.respond_to?(:definition)
        into_child_t  = accumulated_t * e.transformation
        sub_ents      = e.definition.entities
        has_children  = sub_ents.any? { |s|
          s.is_a?(Sketchup::ComponentInstance) || s.is_a?(Sketchup::Group)
        }
        if has_children
          result.concat(collect_beams_recursive(sub_ents, into_child_t))
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

    # Select start/end anchor corners and compute the perpendicular offset vector
    # for a single beam's own-length dimension.
    #
    # :vertical   - projects corners onto view_v; measures the true height.
    # :horizontal - projects corners onto view_h; measures the true width.
    # :diagonal   - uses the component's local definition bounds to find the
    #               longest axis, then computes the face centroids at each end
    #               and transforms them to world space. This gives the true
    #               center-to-center beam length (not an inflated bbox diagonal
    #               or a deflated PCA projection).
    #
    # All three orientations share the same CCW-perpendicular offset formula so the
    # dimension line always sits at exactly 90° to the measured segment.
    def beam_length_anchors(child, world_t, child_corners, hs, vs, _h_extent, _v_extent,
                            beam_axis, view_h, view_v)
      case beam_axis
      when :vertical
        top_grp  = child_corners.select { |c| (dot(c, view_v) - vs.max).abs <= DEDUP_EPSILON }
        top_grp  = child_corners if top_grp.empty?
        bot_grp  = child_corners.select { |c| (dot(c, view_v) - vs.min).abs <= DEDUP_EPSILON }
        bot_grp  = child_corners if bot_grp.empty?
        start_pt = top_grp.min_by { |c| dot(c, view_h) }
        end_pt   = bot_grp.min_by { |c| dot(c, view_h) }
        return [start_pt, end_pt, scale_vec(view_h.reverse, BEAM_LENGTH_OFFSET)]
      when :horizontal
        left_grp  = child_corners.select { |c| (dot(c, view_h) - hs.min).abs <= DEDUP_EPSILON }
        left_grp  = child_corners if left_grp.empty?
        right_grp = child_corners.select { |c| (dot(c, view_h) - hs.max).abs <= DEDUP_EPSILON }
        right_grp = child_corners if right_grp.empty?
        start_pt = left_grp.max_by  { |c| dot(c, view_v) }
        end_pt   = right_grp.max_by { |c| dot(c, view_v) }
      else # :diagonal - face centroids along the beam's longest local axis
        start_pt, end_pt = diagonal_beam_endpoints(child, world_t)
      end

      # CCW 90° of (dh, dv) in view space.
      # For :horizontal (dh>0, dv≈0) this evaluates to +view_v (dim above).
      # For :diagonal it follows the beam angle exactly.
      dh      = dot(end_pt, view_h) - dot(start_pt, view_h)
      dv      = dot(end_pt, view_v) - dot(start_pt, view_v)
      beam_2d = Math.sqrt(dh**2 + dv**2)
      perp = if beam_2d > 0.001.mm
        Geom::Vector3d.new(
          (-view_h.x * dv + view_v.x * dh) / beam_2d,
          (-view_h.y * dv + view_v.y * dh) / beam_2d,
          (-view_h.z * dv + view_v.z * dh) / beam_2d
        )
      else
        view_v
      end
      [start_pt, end_pt, scale_vec(perp, BEAM_LENGTH_OFFSET)]
    end

    # Compute the true center-to-center endpoints of a diagonal beam using its
    # local definition bounds. The longest local axis gives the beam direction;
    # face centroids at each end of that axis, transformed to world space, yield
    # the correct measurement points.
    def diagonal_beam_endpoints(child, world_t)
      full_t = world_t * child.transformation
      db     = child.definition.bounds
      extents = [db.max.x - db.min.x, db.max.y - db.min.y, db.max.z - db.min.z]
      axis_i  = extents.each_with_index.max_by { |v, _| v }[1]

      mid = Geom::Point3d.new(
        (db.min.x + db.max.x) / 2.0,
        (db.min.y + db.max.y) / 2.0,
        (db.min.z + db.max.z) / 2.0
      )

      coords_a = [mid.x, mid.y, mid.z]
      coords_b = [mid.x, mid.y, mid.z]
      coords_a[axis_i] = [db.min.x, db.min.y, db.min.z][axis_i]
      coords_b[axis_i] = [db.max.x, db.max.y, db.max.z][axis_i]

      ep1 = Geom::Point3d.new(*coords_a).transform(full_t)
      ep2 = Geom::Point3d.new(*coords_b).transform(full_t)
      [ep1, ep2]
    end

    def debug(msg)
      return unless @debug
      puts "[SkeletonDimensions] #{msg}"
    end

  end
end
