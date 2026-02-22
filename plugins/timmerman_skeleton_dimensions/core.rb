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
#
# Structure: core.rb defines constants and orchestration (run, clear, add_skeleton_dimensions).
# Helpers, cumulative dimensions, and label logic live in helpers.rb, dimension_cumulative.rb, label.rb.

require 'sketchup.rb'

module Timmerman
  module SkeletonDimensions
    extend self

    %i[
      OUTER_PADDING STAGGER_STEP BEAM_LENGTH_OFFSET DIAG_OFFSET_PADDING
      DIM_FOLDER DIM_LAYER_PREFIX DEDUP_EPSILON MIN_DIMENSION_GAP MIN_BEAM_SPAN
      AXIS_ALIGN_TOL MAX_DIMENSIONS_PER_RUN VERSION DIMENSIONS_LABEL_PREFIX
    ].each { |c| remove_const(c) if const_defined?(c, false) }

    @debug = false
    def debug_mode=(val)
      @debug = val
    end

    # ---------------------------------------------------------------------------
    # Layout constants (SketchUp internal units; .mm converts mm to inches)
    # ---------------------------------------------------------------------------
    OUTER_PADDING = 200.mm
    STAGGER_STEP = 150.mm
    BEAM_LENGTH_OFFSET = 80.mm
    DIAG_OFFSET_PADDING = 200.mm
    DIM_FOLDER = 'maten'.freeze
    DIM_LAYER_PREFIX = 'maten '.freeze
    DEDUP_EPSILON = 0.1.mm
    MIN_DIMENSION_GAP = 1.mm
    MIN_BEAM_SPAN = 10.mm
    AXIS_ALIGN_TOL = 0.001
    MAX_DIMENSIONS_PER_RUN = 400
    VERSION = '-development'.freeze
    DIMENSIONS_LABEL_PREFIX = 'Dimensions: '.freeze

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

      model.active_layer = sublayer
      model.active_view.invalidate
      debug("Done. Added #{count} dimension(s).")
      show_dimensions_created_notification
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
      target_entities = entities_containing_instance(inst)
      dims     = target_entities.grep(Sketchup::DimensionLinear).select { |d| d.layer == sublayer }
      label_texts = target_entities.grep(Sketchup::Text).select { |t|
        t.layer == sublayer && t.text.to_s.start_with?(DIMENSIONS_LABEL_PREFIX)
      }
      if dims.empty? && label_texts.empty?
        debug('No linear dimensions or label found to clear.')
        return
      end

      model.start_operation('Clear Skeleton Dimensions', true)
      begin
        target_entities.erase_entities(dims) unless dims.empty?
        target_entities.erase_entities(label_texts) unless label_texts.empty?
      rescue => e
        model.abort_operation
        UI.messagebox("Clear Dimensions failed:\n#{e.message}")
        return
      end
      model.commit_operation

      model.active_view.invalidate
      debug("Cleared #{dims.size} dimension(s)#{label_texts.empty? ? '' : " and #{label_texts.size} label(s)"}.")
    end

    # ---------------------------------------------------------------------------
    # Core algorithm (orchestration only; helpers in helpers.rb, etc.)
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

      depth_projs = all_beam_corners.map { |c| dot(c, view_dir) }
      cam_depth   = depth_projs.max - depth_projs.min
      cam_nudge   = scale_vec(view_dir.reverse, cam_depth)
      nudge = ->(pt) {
        Geom::Point3d.new(pt.x + cam_nudge.x, pt.y + cam_nudge.y, pt.z + cam_nudge.z)
      }

      bottom_left_per_beam = structural_beams.map { |child, world_t|
        corners = (0..7).map { |i| child.bounds.corner(i).transform(world_t) }
        corners.min_by { |c| [dot(c, view_h), dot(c, view_v)] }
      }
      origin_pt = bottom_left_per_beam.min_by { |c| [dot(c, view_h), dot(c, view_v)] }
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

      entities = entities_containing_instance(inst)
      count    = 0
      max_dimensions_cap = MAX_DIMENSIONS_PER_RUN

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
        nudge: nudge, sublayer: sublayer, max_count: max_dimensions_cap
      )
      count += below_count
      if max_dimensions_cap && count >= max_dimensions_cap
        debug("Stopped at #{MAX_DIMENSIONS_PER_RUN} dimensions (cap) to avoid view overload.")
        return count
      end

      above_count = emit_cumulative_dims(
        entities, unique_x_top, origin_x,
        ->(pt) { beam_max_v - dot(pt, view_v) },
        view_v,
        make_base_pt: make_base_pt, make_h_anchor: make_h_anchor,
        nudge: nudge, sublayer: sublayer, max_count: max_dimensions_cap
      )
      count += above_count
      if max_dimensions_cap && count >= max_dimensions_cap
        debug("Stopped at #{MAX_DIMENSIONS_PER_RUN} dimensions (cap) to avoid view overload.")
        return count
      end

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
        else
          sh = (dot(start_pt, view_h) / DEDUP_EPSILON).round
          sv = (dot(start_pt, view_v) / DEDUP_EPSILON).round
          eh = (dot(end_pt,   view_h) / DEDUP_EPSILON).round
          ev = (dot(end_pt,   view_v) / DEDUP_EPSILON).round
          [:d, *[[sh, sv], [eh, ev]].sort.flatten]
        end

        next if added_length_axis[key]
        added_length_axis[key] = true
        break if max_dimensions_cap && count >= max_dimensions_cap

        align_dim(
          entities.add_dimension_linear(nudge.call(start_pt), nudge.call(end_pt), offset),
          sublayer
        )
        count += 1
      end

      beam_max_h = all_beam_corners.map { |c| dot(c, view_h) }.max
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

      center_pt = Geom::Point3d.new(
        origin_pt.x + view_h.x * (beam_max_h - origin_x) * 0.5 + view_v.x * ((beam_min_v + beam_max_v) * 0.5 - origin_y) + view_dir.x * depth_off,
        origin_pt.y + view_h.y * (beam_max_h - origin_x) * 0.5 + view_v.y * ((beam_min_v + beam_max_v) * 0.5 - origin_y) + view_dir.y * depth_off,
        origin_pt.z + view_h.z * (beam_max_h - origin_x) * 0.5 + view_v.z * ((beam_min_v + beam_max_v) * 0.5 - origin_y) + view_dir.z * depth_off
      )
      top_right_pt = Geom::Point3d.new(
        origin_pt.x + view_h.x * (beam_max_h - origin_x) + view_v.x * (beam_max_v - origin_y) + view_dir.x * depth_off,
        origin_pt.y + view_h.y * (beam_max_h - origin_x) + view_v.y * (beam_max_v - origin_y) + view_dir.y * depth_off,
        origin_pt.z + view_h.z * (beam_max_h - origin_x) + view_v.z * (beam_max_v - origin_y) + view_dir.z * depth_off
      )
      bottom_right_pt = Geom::Point3d.new(
        origin_pt.x + view_h.x * (beam_max_h - origin_x) + view_v.x * (beam_min_v - origin_y) + view_dir.x * depth_off,
        origin_pt.y + view_h.y * (beam_max_h - origin_x) + view_v.y * (beam_min_v - origin_y) + view_dir.y * depth_off,
        origin_pt.z + view_h.z * (beam_max_h - origin_x) + view_v.z * (beam_min_v - origin_y) + view_dir.z * depth_off
      )
      bottom_left_pt = Geom::Point3d.new(
        origin_pt.x + view_v.x * (beam_min_v - origin_y) + view_dir.x * depth_off,
        origin_pt.y + view_v.y * (beam_min_v - origin_y) + view_dir.y * depth_off,
        origin_pt.z + view_v.z * (beam_min_v - origin_y) + view_dir.z * depth_off
      )

      tl_br_len = tl.distance(br)
      if tl_br_len >= MIN_DIMENSION_GAP && (!max_dimensions_cap || count < max_dimensions_cap)
        perp_tb, diag_off_tb = diagonal_offset_outside(
          tl, br, center_pt, top_right_pt, top_right_pt, bottom_left_pt, view_h, view_v
        )
        align_dim(
          entities.add_dimension_linear(nudge.call(tl), nudge.call(br), scale_vec(perp_tb, diag_off_tb)),
          sublayer,
          prefix: "◩ "
        )
        count += 1

        bt_2d = bottom_left_pt.distance(top_right_pt)
        if bt_2d >= MIN_DIMENSION_GAP && (!max_dimensions_cap || count < max_dimensions_cap)
          perp_bt, diag_off_bt = diagonal_offset_outside(
            bottom_left_pt, top_right_pt, center_pt, bottom_right_pt, bottom_right_pt, tl, view_h, view_v
          )
          align_dim(
            entities.add_dimension_linear(nudge.call(bottom_left_pt), nudge.call(top_right_pt), scale_vec(perp_bt, diag_off_bt)),
            sublayer,
            prefix: "◩ "
          )
          count += 1
        end
      end

      add_dimensions_created_label(entities, nudge.call(bottom_right_pt), view_h, view_v, sublayer)

      count
    end
  end
end

# Load sub-components (they add methods to Timmerman::SkeletonDimensions)
dir = File.dirname(__FILE__)
load File.join(dir, 'helpers.rb')
load File.join(dir, 'dimension_cumulative.rb')
load File.join(dir, 'label.rb')
