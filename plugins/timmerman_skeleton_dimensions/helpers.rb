# encoding: utf-8
# helpers.rb — geometry, classification, layer/selection, beam anchors.
# Methods are added to Timmerman::SkeletonDimensions (loaded by core.rb).

module Timmerman
  module SkeletonDimensions
    # -------------------------------------------------------------------------
    # Geometry & classification
    # -------------------------------------------------------------------------

    def classify_beam(e, world_t, h_extent, v_extent, view_h, view_v, view_dir)
      full_t  = world_t * e.transformation
      aligned = [full_t.xaxis, full_t.yaxis, full_t.zaxis].all? { |ax|
        n = ax.normalize
        [view_h, view_v, view_dir].any? { |ref| n.dot(ref).abs > 1.0 - AXIS_ALIGN_TOL }
      }
      return :diagonal unless aligned
      h_extent >= v_extent ? :horizontal : :vertical
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

    def scale_vec(vec, scalar)
      Geom::Vector3d.new(vec.x * scalar, vec.y * scalar, vec.z * scalar)
    end

    def dot(pt, axis)
      pt.x * axis.x + pt.y * axis.y + pt.z * axis.z
    end

    # Project 3D points to view plane, compute 2D convex hull (Andrew's monotone chain),
    # then pick BL/TL/TR/BR as the hull vertex nearest each bbox corner.
    # Returns [bl_pt, tl_pt, tr_pt, br_pt] or nil.
    def frame_corners_from_silhouette_hull(points_3d, view_h, view_v)
      return nil if points_3d.size < 2
      pts_2d = points_3d.map { |p| { u: dot(p, view_h), v: dot(p, view_v), pt: p } }
      hull = convex_hull_2d(pts_2d)
      return nil if hull.size < 2

      us = hull.map { |q| q[:u] }
      vs = hull.map { |q| q[:v] }
      min_u, max_u = us.min, us.max
      min_v, max_v = vs.min, vs.max

      nearest = ->(target_u, target_v) {
        hull.min_by { |q| (q[:u] - target_u)**2 + (q[:v] - target_v)**2 }
      }

      bl = nearest.call(min_u, min_v)
      tl = nearest.call(min_u, max_v)
      tr = nearest.call(max_u, max_v)
      br = nearest.call(max_u, min_v)
      [bl[:pt], tl[:pt], tr[:pt], br[:pt]]
    end

    # Andrew's monotone chain: 2D convex hull. pts = [{ u:, v:, pt: }, ...]. Returns hull vertices (with :pt).
    def convex_hull_2d(pts)
      return pts.dup if pts.size <= 2
      sorted = pts.sort_by { |p| [p[:u], p[:v]] }
      cross = ->(o, a, b) { (a[:u] - o[:u]) * (b[:v] - o[:v]) - (a[:v] - o[:v]) * (b[:u] - o[:u]) }
      lower = []
      sorted.each do |p|
        lower.pop while lower.size >= 2 && cross.call(lower[-2], lower[-1], p) <= 0
        lower << p
      end
      upper = []
      sorted.reverse_each do |p|
        upper.pop while upper.size >= 2 && cross.call(upper[-2], upper[-1], p) <= 0
        upper << p
      end
      (lower[0..-2] + upper[0..-2]).uniq
    end

    def diagonal_offset_outside(start_pt, end_pt, center_pt, tiebreaker_pt, corner_a, corner_b, view_h, view_v)
      dh = dot(end_pt, view_h) - dot(start_pt, view_h)
      dv = dot(end_pt, view_v) - dot(start_pt, view_v)
      len_2d = Math.sqrt(dh**2 + dv**2)
      perp = Geom::Vector3d.new(
        (-view_h.x * dv + view_v.x * dh) / len_2d,
        (-view_h.y * dv + view_v.y * dh) / len_2d,
        (-view_h.z * dv + view_v.z * dh) / len_2d
      )
      mid = Geom::Point3d.new((start_pt.x + end_pt.x) * 0.5, (start_pt.y + end_pt.y) * 0.5, (start_pt.z + end_pt.z) * 0.5)
      out_sign = (center_pt.x - mid.x) * perp.x + (center_pt.y - mid.y) * perp.y + (center_pt.z - mid.z) * perp.z
      sign = if out_sign > 0 then -1
      elsif out_sign < 0 then 1
      else (tiebreaker_pt.x - mid.x) * perp.x + (tiebreaker_pt.y - mid.y) * perp.y + (tiebreaker_pt.z - mid.z) * perp.z > 0 ? 1 : -1
      end
      dist_a = (corner_a.x - mid.x) * perp.x + (corner_a.y - mid.y) * perp.y + (corner_a.z - mid.z) * perp.z
      dist_b = (corner_b.x - mid.x) * perp.x + (corner_b.y - mid.y) * perp.y + (corner_b.z - mid.z) * perp.z
      corner_dist = sign > 0 ? [dist_a, dist_b].max : -[dist_a, dist_b].min
      [perp, sign * (corner_dist + DIAG_OFFSET_PADDING)]
    end

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

    # Actual geometry points of a beam (vertices from edges/faces), not bbox. For angled beams these are the real corners.
    # Returns array of Point3d in the same space as world_t (use full_t = world_t * child.transformation for child's local geom).
    def beam_geometry_points(child, world_t)
      full_t = world_t * child.transformation
      pts = []
      child.definition.entities.each do |e|
        if e.is_a?(Sketchup::Edge)
          pts << e.start.position.transform(full_t)
          pts << e.end.position.transform(full_t)
        elsif e.is_a?(Sketchup::Face)
          e.vertices.each { |v| pts << v.position.transform(full_t) }
        end
      end
      # Dedupe by position (within epsilon) so we don't get huge arrays for dense meshes.
      pts.uniq { |p| [p.x, p.y, p.z].map { |c| (c / DEDUP_EPSILON).round }.freeze }
    end

    def beam_length_anchors(child, world_t, child_corners, geom_pts, hs, vs, _h_extent, _v_extent,
                            beam_axis, view_h, view_v)
      case beam_axis
      when :vertical
        top_pt = geom_pts.max_by { |c| dot(c, view_v) }
        bot_pt = geom_pts.min_by { |c| dot(c, view_v) }
        h_mid  = (hs.min + hs.max) / 2.0
        left_v  = geom_pts.select { |c| dot(c, view_h) < h_mid }.map { |c| dot(c, view_v) }
        right_v = geom_pts.select { |c| dot(c, view_h) >= h_mid }.map { |c| dot(c, view_v) }
        left_span  = left_v.empty?  ? 0 : left_v.max - left_v.min
        right_span = right_v.empty? ? 0 : right_v.max - right_v.min
        side = right_span >= left_span ? view_h : view_h.reverse
        return [top_pt, bot_pt, scale_vec(side, BEAM_LENGTH_OFFSET)]
      when :horizontal
        start_pt = geom_pts.min_by { |c| dot(c, view_h) }
        end_pt   = geom_pts.max_by { |c| dot(c, view_h) }
        v_mid  = (vs.min + vs.max) / 2.0
        top_h  = geom_pts.select { |c| dot(c, view_v) >= v_mid }.map { |c| dot(c, view_h) }
        bot_h  = geom_pts.select { |c| dot(c, view_v) < v_mid }.map { |c| dot(c, view_h) }
        top_span = top_h.empty? ? 0 : top_h.max - top_h.min
        bot_span = bot_h.empty? ? 0 : bot_h.max - bot_h.min
        side = top_span >= bot_span ? view_v : view_v.reverse
        return [start_pt, end_pt, scale_vec(side, BEAM_LENGTH_OFFSET)]
      else
        start_pt, end_pt = diagonal_beam_endpoints(child, world_t)
      end

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

    # -------------------------------------------------------------------------
    # Layer & selection
    # -------------------------------------------------------------------------

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
      sub_layer.visible = true

      debug("Dimension sublayer: '#{sub_name}' (folder: '#{parent_folder ? parent_folder.name : 'none'}')")
      sub_layer
    end

    def selected_component_instance(selection)
      candidates = selection.grep(Sketchup::ComponentInstance)
      return nil unless candidates.length == 1
      candidates.first
    end

    def entities_containing_instance(inst)
      parent = inst.parent
      return inst.model.entities if parent.is_a?(Sketchup::Model)
      return parent if parent.respond_to?(:grep) && parent.respond_to?(:erase_entities)
      inst.model.entities
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

    def debug(msg)
      return unless @debug
      puts "[SkeletonDimensions] #{msg}"
    end
  end
end
