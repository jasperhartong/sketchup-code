# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Translates an array of Part value objects (from a FrameAssembly) into real
    # SketchUp groups.  All geometry decisions live in the frame classes; this
    # class only knows about the SketchUp API.
    #
    # Usage:
    #   renderer = SketchUpRenderer.new(config, model)
    #   renderer.render_frame(frame, parent_entities, layer:, stock_planner:, preview_rgb:)
    class SketchUpRenderer
      # RGB per outward face key (axis-aligned box parts only).
      FACE_DEBUG_RGB = {
        min_x: [230,  60,  60].freeze,
        max_x: [160,  40,  40].freeze,
        min_y: [ 60, 230,  60].freeze,
        max_y: [ 40, 160,  40].freeze,
        min_z: [ 60,  60, 230].freeze,
        max_z: [120, 120, 240].freeze
      }.freeze

      def initialize(config, model)
        @config = config
        @model  = model
      end

      # Renders a complete FrameAssembly into +parent_entities+.
      # +stock_planner+ (optional) receives every Beam for the cut-list tally.
      # +preview_rgb+   (optional) [r,g,b] painted on all faces for shaded view.
      # Returns the SketchUp::Group that was created.
      def render_frame(frame, parent_entities, layer:, stock_planner: nil, preview_rgb: nil)
        root = parent_entities.add_group
        root.name  = frame.group_name
        root.layer = layer

        frame.parts.each do |part|
          add_part(root.entities, part, layer: layer)
          stock_planner.record(part) if stock_planner && part.is_a?(Beam)
        end

        render_hardware(frame, root, layer)
        stock_planner&.then { |planner| (frame.hardware || []).each { |pl| planner.record_screw(pl) } }

        if preview_rgb && !@config.debug_paint_faces
          paint_preview(root, preview_rgb)
        end
        root
      end

      # Cuts countersink + clearance hole in host part groups and adds screw leaf groups.
      def render_hardware(frame, root, layer)
        (frame.hardware || []).each do |placement|
          _render_one_screw(frame, root, layer, placement)
        end
      end

      # Paints each axis-aligned face of every direct child part (excludes `EB | screw |`).
      def paint_axis_aligned_faces_for_debug(root)
        return unless @config.debug_paint_faces

        root.entities.grep(Sketchup::Group).each do |child|
          next if Config::SCREW_NAME_RE.match?(child.name)

          _paint_box_faces_debug(child.entities)
        end
      end

      # Re-paints direct child groups whose names match +names+ (Outliner part names).
      def repaint_named_children(root, names, rgb)
        return if names.nil? || names.empty?

        mat = _ensure_material(rgb)
        Array(names).each do |name|
          g = root.entities.grep(Sketchup::Group).find { |c| c.name == name }
          _paint_recursive(g.entities, mat) if g
        end
      end

      # Renders a single Part into the given entities without wrapping in a root.
      # Used by BedPair to add pillows directly to an existing root group.
      def add_part(entities, part, layer: nil)
        g       = entities.add_group
        g.name  = part.name
        g.layer = layer if layer
        g.set_attribute(Config::ATTR_DICT, 'note', part.note) if part.note && !part.note.empty?
        _add_box(g.entities, 0, 0, 0, part.dx, part.dy, part.dz)
        g.transformation = Geom::Transformation.translation([part.x, part.y, part.z])
        g
      end

      private

      def _render_one_screw(frame, root, layer, placement)
        host = root.entities.grep(Sketchup::Group).find { |g| g.name == placement.host_name }
        unless host
          warn "[EB hardware] host group not found: #{placement.host_name.inspect}"
          return
        end

        part = frame.parts.find { |p| p.name == placement.host_name }
        unless part
          warn "[EB hardware] host part not in frame.parts: #{placement.host_name.inspect}"
          return
        end

        spec = @config.screw_spec(placement.spec_id)
        geo  = _face_geometry(placement.face, part.dx, part.dy, part.dz, placement.u, placement.v)
        _apply_pocket_tilt_outward!(geo, placement)

        if @config.hardware_cut_hosts && _screw_perpendicular_to_face?(placement)
          begin
            _cut_countersink_and_shaft(host.entities, geo, part, spec)
          rescue StandardError => e
            warn "[EB hardware] hole/countersink failed for #{placement.name.inspect}: #{e.message}"
          end
        end

        unless host.valid?
          warn "[EB hardware] host group invalid after cut: #{placement.host_name.inspect}"
          return
        end

        tr = _screw_group_transformation(host.transformation, geo)
        _add_screw_body(root.entities, layer, placement.name, tr, spec, placement.shaft_length_index)
      rescue StandardError => e
        warn "[EB hardware] screw #{placement.name.inspect}: #{e.message}"
      end

      # Pocket screws: tilt shaft direction from ±face normal in the (normal, tangent) plane.
      # See `ScrewPlacement` for `pocket_away_from_host` and `pocket_tilt_from_normal_deg`.
      #
      # With **tilt 0** and `pocket_away_from_host: true`, negate the face outward normal so the
      # shaft runs **into the mate across the interface** (e.g. :max_z on a beam under a slat:
      # head stays beam-side, shaft +Z into the slat instead of default +Z head / −Z into beam).
      def _apply_pocket_tilt_outward!(geo, placement)
        o = geo[:outward].clone
        o.normalize!
        rad = placement.pocket_tilt_from_normal_deg * Math::PI / 180.0

        if rad.abs < 1e-9
          geo[:outward] = o.reverse if placement.pocket_away_from_host
          return geo
        end

        t = _pocket_tangent_unit(placement.face, placement.pocket_tilt_toward)
        base = placement.pocket_away_from_host ? o : o.reverse
        shaft = _vec_combine(Math.cos(rad), base, Math.sin(rad), t)
        shaft.normalize!
        geo[:outward] = shaft.reverse
        geo
      end

      def _screw_perpendicular_to_face?(placement)
        placement.pocket_tilt_from_normal_deg.abs < 1e-9 && !placement.pocket_away_from_host
      end

      def _vec_combine(a, va, b, vb)
        Geom::Vector3d.new(
          (a * va.x) + (b * vb.x),
          (a * va.y) + (b * vb.y),
          (a * va.z) + (b * vb.z)
        )
      end

      # Unit tangent on the box face (part-local, axis-aligned); matches `ScrewPlacement` UV docs.
      def _pocket_tangent_unit(face, toward)
        u_hat, v_hat = case face
                       when :min_x, :max_x then [Y_AXIS.clone, Z_AXIS.clone]
                       when :min_y, :max_y then [X_AXIS.clone, Z_AXIS.clone]
                       when :min_z, :max_z then [X_AXIS.clone, Y_AXIS.clone]
                       else
                         raise ArgumentError, "unknown face #{face.inspect}"
                       end
        vec = case toward
              when :pos_u then u_hat
              when :neg_u then u_hat.reverse
              when :pos_v then v_hat
              when :neg_v then v_hat.reverse
              else
                raise ArgumentError, "unknown toward #{toward.inspect}"
              end
        out = vec.clone
        out.normalize!
        out
      end

      # @return [Hash] :origin, :outward, :axis_thickness, :face_key, :dx, :dy, :dz
      def _face_geometry(face, dx, dy, dz, u, v)
        case face
        when :min_x
          o = Geom::Point3d.new(0, 0, 0).offset(Y_AXIS, u).offset(Z_AXIS, v)
          { origin: o, outward: Geom::Vector3d.new(-1, 0, 0), axis_thickness: dx,
            face_key: :min_x, dx: dx, dy: dy, dz: dz }
        when :max_x
          o = Geom::Point3d.new(dx, 0, 0).offset(Y_AXIS, u).offset(Z_AXIS, v)
          { origin: o, outward: Geom::Vector3d.new(1, 0, 0), axis_thickness: dx,
            face_key: :max_x, dx: dx, dy: dy, dz: dz }
        when :min_y
          o = Geom::Point3d.new(0, 0, 0).offset(X_AXIS, u).offset(Z_AXIS, v)
          { origin: o, outward: Geom::Vector3d.new(0, -1, 0), axis_thickness: dy,
            face_key: :min_y, dx: dx, dy: dy, dz: dz }
        when :max_y
          o = Geom::Point3d.new(0, dy, 0).offset(X_AXIS, u).offset(Z_AXIS, v)
          { origin: o, outward: Geom::Vector3d.new(0, 1, 0), axis_thickness: dy,
            face_key: :max_y, dx: dx, dy: dy, dz: dz }
        when :min_z
          o = Geom::Point3d.new(0, 0, 0).offset(X_AXIS, u).offset(Y_AXIS, v)
          { origin: o, outward: Geom::Vector3d.new(0, 0, -1), axis_thickness: dz,
            face_key: :min_z, dx: dx, dy: dy, dz: dz }
        when :max_z
          o = Geom::Point3d.new(0, 0, dz).offset(X_AXIS, u).offset(Y_AXIS, v)
          { origin: o, outward: Geom::Vector3d.new(0, 0, 1), axis_thickness: dz,
            face_key: :max_z, dx: dx, dy: dy, dz: dz }
        else
          raise ArgumentError, "unknown face #{face.inspect}"
        end
      end

      # Cuts use add_circle + add_face + pushpull on the host leaf group. SketchUp 2026 may
      # invalidate the host when a circle is faceted onto a thin plank top; keep
      # `Config#hardware_cut_hosts` false until we switch to `Face#split` / guided hole workflow.
      def _cut_countersink_and_shaft(entities, geo, _part, spec)
        origin  = geo[:origin]
        outward = geo[:outward].clone
        outward.normalize!
        d_cs = spec.countersink_depth
        r_cs = spec.countersink_diameter * 0.5
        r_hole = (spec.shaft_diameter * 0.5) + 0.25.mm
        thick = geo[:axis_thickness]

        outer = _outer_face_for_box_face(entities, geo)
        return unless outer

        pt0 = _project_point_to_face_plane(origin, outer)

        if @config.hardware_countersink_first
          # 1) Countersink pocket, 2) through hole from pocket floor.
          edges_cs = entities.add_circle(pt0, outer.normal, r_cs, 24)
          f_cs = entities.add_face(edges_cs)
          return unless f_cs

          f_cs.reverse! unless f_cs.normal.samedirection?(outward)
          f_cs.pushpull(-d_cs)

          return unless @config.hardware_through_hole

          floor = pt0.offset(outward, -d_cs)
          remain = thick - d_cs + 1.mm
          return if remain <= 0

          floor_face = _face_closest_to_point(entities, floor, outward)
          unless floor_face
            warn '[EB hardware] could not find pocket floor face; countersink only (no through hole)'
            return
          end

          pt1 = _project_point_to_face_plane(floor, floor_face)
          edges_h = entities.add_circle(pt1, floor_face.normal, r_hole, 24)
          f_h = entities.add_face(edges_h)
          return unless f_h

          f_h.reverse! unless f_h.normal.samedirection?(outward)
          f_h.pushpull(-remain)
        else
          # Single through clearance hole (more stable than pocket + bore in SU 2026).
          edges_h = entities.add_circle(pt0, outer.normal, r_hole, 24)
          f_h = entities.add_face(edges_h)
          return unless f_h

          f_h.reverse! unless f_h.normal.samedirection?(outward)
          bore = [thick - 2.mm, thick * 0.98].min
          f_h.pushpull(-bore)
        end
      end

      # Largest box face on the given side (avoids picking an interior cap when several +Z faces exist).
      def _outer_face_for_box_face(entities, geo)
        dx, dy, dz = geo[:dx], geo[:dy], geo[:dz]
        tol = 0.75.mm
        case geo[:face_key]
        when :max_z
          _pick_face_at_z(entities, dz, tol, Z_AXIS)
        when :min_z
          _pick_face_at_z(entities, 0, tol, Geom::Vector3d.new(0, 0, -1))
        when :max_x
          _pick_face_at_x(entities, dx, tol, X_AXIS)
        when :min_x
          _pick_face_at_x(entities, 0, tol, Geom::Vector3d.new(-1, 0, 0))
        when :max_y
          _pick_face_at_y(entities, dy, tol, Y_AXIS)
        when :min_y
          _pick_face_at_y(entities, 0, tol, Geom::Vector3d.new(0, -1, 0))
        end
      end

      def _pick_face_at_z(entities, z_plane, tol, normal)
        entities.grep(Sketchup::Face).select do |f|
          f.valid? && f.normal.samedirection?(normal) && (f.bounds.center.z - z_plane).abs < tol
        end.max_by(&:area)
      end

      def _pick_face_at_x(entities, x_plane, tol, normal)
        entities.grep(Sketchup::Face).select do |f|
          f.valid? && f.normal.samedirection?(normal) && (f.bounds.center.x - x_plane).abs < tol
        end.max_by(&:area)
      end

      def _pick_face_at_y(entities, y_plane, tol, normal)
        entities.grep(Sketchup::Face).select do |f|
          f.valid? && f.normal.samedirection?(normal) && (f.bounds.center.y - y_plane).abs < tol
        end.max_by(&:area)
      end

      # Among faces with +outward+ normal, pick the one whose bounds center is closest to +point+
      # (used for the pocket floor after countersink).
      def _face_closest_to_point(entities, point, outward)
        out = outward.clone
        out.normalize!
        entities.grep(Sketchup::Face).select do |f|
          f.valid? && f.normal.samedirection?(out)
        end.min_by { |f| f.bounds.center.distance(point) }
      end

      def _project_point_to_face_plane(pt, face)
        q = pt.clone
        p0 = face.outer_loop.vertices[0].position
        n = face.normal.clone
        n.normalize!
        d = (q - p0).dot(n)
        q.offset(n, -d)
      end

      # Screw local: origin on outer flush point, +Z = outward (head), shaft in -Z.
      def _screw_group_transformation(host_tr, geo)
        outward = geo[:outward].clone
        outward.normalize!
        xaxis, yaxis, zaxis = _orthonormal_frame(outward)
        origin = geo[:origin]
        local_to_host = Geom::Transformation.axes(origin, xaxis, yaxis, zaxis)
        host_tr * local_to_host
      end

      def _orthonormal_frame(outward)
        z = outward.clone
        z.normalize!
        ref = (z.parallel?(Z_AXIS) ? X_AXIS : Z_AXIS)
        x = z.cross(ref)
        x.normalize!
        y = z.cross(x)
        y.normalize!
        [x, y, z]
      end

      def _add_screw_body(parent_entities, layer, name, transform, spec, shaft_idx)
        g = parent_entities.add_group
        g.name  = name
        g.layer = layer if layer
        g.transformation = transform
        ents = g.entities

        r_shaft = spec.shaft_diameter * 0.5
        l_shaft = spec.shaft_length_at(shaft_idx)
        r_head  = spec.head_diameter * 0.5
        h_head  = spec.head_height

        # Screw local +Z = outward from wood. Keep all solid at z <= 0 so the outer plane is flush
        # (no head sticking past the entry face).
        edges_h = ents.add_circle(ORIGIN, Z_AXIS, r_head, 24)
        f_h = ents.add_face(edges_h)
        return unless f_h

        f_h.reverse! if f_h.normal.z < 0
        f_h.pushpull(-h_head)

        shaft_pull = [l_shaft - h_head, 0.1.mm].max
        base = Geom::Point3d.new(0, 0, -l_shaft)
        edges_s = ents.add_circle(base, Z_AXIS, r_shaft, 24)
        f_s = ents.add_face(edges_s)
        return unless f_s

        f_s.reverse! if f_s.normal.z < 0
        f_s.pushpull(shaft_pull)

        metal = _ensure_material([168, 172, 180])
        _paint_recursive(ents, metal)
      end

      def _paint_box_faces_debug(entities)
        entities.grep(Sketchup::Face).each do |f|
          next unless f.valid?

          key = _classify_axis_face(f.normal)
          next unless key

          rgb = FACE_DEBUG_RGB[key]
          mat = _ensure_material(rgb)
          f.material      = mat
          f.back_material = mat
        end
      end

      def _classify_axis_face(normal)
        n = normal.clone
        n.normalize!
        return nil if [n.x.abs, n.y.abs, n.z.abs].max < 0.85

        if n.z.abs >= n.x.abs && n.z.abs >= n.y.abs
          n.z.positive? ? :max_z : :min_z
        elsif n.y.abs >= n.x.abs
          n.y.positive? ? :max_y : :min_y
        else
          n.x.positive? ? :max_x : :min_x
        end
      end

      # ── Box geometry ─────────────────────────────────────────────────────────

      # Pushes a rectangular solid into +entities+ with one corner at the origin.
      def _add_box(entities, x, y, z, dx, dy, dz)
        pts = [
          Geom::Point3d.new(x,      y,      z),
          Geom::Point3d.new(x + dx, y,      z),
          Geom::Point3d.new(x + dx, y + dy, z),
          Geom::Point3d.new(x,      y + dy, z)
        ]
        f = entities.add_face(pts)
        f.reverse! if f.normal.z < 0
        f.pushpull(dz)
      end

      # ── Preview materials ─────────────────────────────────────────────────────

      def paint_preview(group, rgb)
        mat = _ensure_material(rgb)
        _paint_recursive(group.entities, mat)
      end

      def _ensure_material(rgb)
        name = "EB preview | #{rgb.join(',')}"
        m    = @model.materials[name] || @model.materials.add(name)
        m.color = Sketchup::Color.new(rgb[0], rgb[1], rgb[2])
        m
      end

      def _paint_recursive(entities, material)
        entities.each do |e|
          case e
          when Sketchup::Face
            e.material      = material
            e.back_material = material
          when Sketchup::Group
            _paint_recursive(e.entities, material)
          when Sketchup::ComponentInstance
            _paint_recursive(e.definition.entities, material)
          end
        end
      end
    end
  end
end
