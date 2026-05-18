# frozen_string_literal: true

# SketchUp concrete implementation of the SketchupUtils::Renderer interface.
# This file is the only place in the generic utility layer that touches
# Sketchup::* / Geom::* / add_face / pushpull / materials / layers.

module Timmerman
  module SketchupUtils
    class SketchUpRenderer
      include Renderer

      # RGB per outward face key (axis-aligned box parts only).
      FACE_DEBUG_RGB = {
        min_x: [230,  60,  60].freeze,
        max_x: [160,  40,  40].freeze,
        min_y: [ 60, 230,  60].freeze,
        max_y: [ 40, 160,  40].freeze,
        min_z: [ 60,  60, 230].freeze,
        max_z: [120, 120, 240].freeze
      }.freeze

      # Quarter-circle segments per rounded XY footprint corner (before Z pushpull).
      ROUNDED_BOX_ARC_SEGMENTS = 8
      FULL_ROUNDED_BOX_SEGMENTS = 3
      SCREW_RGB = [128, 128, 128].freeze

      # @param attr_dict [String] SketchUp attribute-dictionary name used for
      #   per-group notes (so parts round-trip with their provenance comment).
      def initialize(model, attr_dict:, debug_color: :off)
        @model             = model
        @attr_dict         = attr_dict
        @debug_color = debug_color.to_sym
        @box_definition_cache = {}
        @screw_definition_cache = {}
        @component_debug_material_cache = {}
        @scene_capture = model ? SketchupUtils::SceneCapture.new(model) : nil
      end

      # Register a scene tab (see SketchupUtils::SceneCapture). Returns a scope;
      # call +scope.track(group)+ for each root that should frame the view.
      # camera: :iso | :top | :front | :back | :left | :right | :bottom
      def scene(name, camera: :iso, &block)
        raise 'scene requires a SketchUp model' unless @scene_capture

        @scene_capture.scene(name, camera: camera, &block)
      end

      # Converts a Group to a ComponentInstance (SketchUp Group#to_component).
      # Returns the new ComponentInstance; the group is replaced in-place.
      # Explicitly copies the group name onto both the instance and its definition,
      # since SketchUp's Group#to_component does not preserve the name automatically.
      def to_component!(group)
        name     = group.name
        instance = group.to_component
        if name && !name.empty?
          instance.name            = name
          instance.definition.name = name
        end
        instance
      end

      # Creates all registered scenes. +purge_all+ removes every existing page first.
      def finalize_scenes(prefix: nil, purge_all: false)
        return [] unless @scene_capture

        @scene_capture.finalize!(prefix: prefix, purge_all: purge_all)
      end

      # ── Scene graph ──────────────────────────────────────────────────────

      def create_group(name, parent:, layer: nil)
        entities = _child_entities(parent)
        g = entities.add_group
        g.name  = name
        g.layer = layer if layer
        g
      end

      # Creates a leaf part as a reusable component instance when possible.
      # Falls back to plain group geometry when reuse is disabled.
      def create_part_box(name, parent:, layer:, size:, transform:, reusable: true, corner_radius: 0, corner_axis: :long)
        unless reusable
          g = create_group(name, parent: parent, layer: layer)
          add_box(g, at: [0, 0, 0], size: size, corner_radius: corner_radius, corner_axis: corner_axis)
          set_group_transform(g, transform)
          return g
        end

        definition = _box_definition(size, corner_radius, corner_axis)
        inst = _child_entities(parent).add_instance(definition, _to_geom_transformation(transform))
        inst.name = name
        inst.layer = layer if layer
        _apply_component_debug_color(inst)
        inst
      end

      def set_group_transform(group, transform)
        group.transformation = _to_geom_transformation(transform)
      end

      def set_group_attribute(group, dict, key, value)
        group.set_attribute(dict, key, value)
      end

      # ── Geometry primitives ─────────────────────────────────────────────

      def add_box(group, at:, size:, corner_radius: 0, corner_axis: :long)
        x,  y,  z  = at.map(&:to_f)
        dx, dy, dz = size.map(&:to_f)
        ents = group.entities
        r_req = corner_radius.to_f
        if r_req <= 0
          _add_sharp_prism_z_extrude(ents, x, y, z, dx, dy, dz)
          return
        end

        basis = _basis_for_corner_axis(x, y, z, dx, dy, dz, corner_axis)
        r = _clamp_plan_corner_radius(basis[:u_len], basis[:v_len], r_req)
        if r <= 1e-9
          _add_sharp_prism_z_extrude(ents, x, y, z, dx, dy, dz)
          return
        end

        return if _try_add_rounded_prism_long_axis_extrude(ents, basis, r)

        warn '[SU renderer] rounded box add_face failed; using sharp corners'
        _add_sharp_prism_z_extrude(ents, x, y, z, dx, dy, dz)
      end

      def add_screw_body(parent_group, name:, transform:, spec:, shaft_length_index:, layer: nil)
        definition = _screw_definition(spec, shaft_length_index)
        inst = parent_group.entities.add_instance(definition, _to_geom_transformation(transform))
        inst.name = name
        inst.layer = layer if layer
        _apply_component_debug_color(inst)
      end

      # geo: hash from PocketGeometry.face_geometry (after apply_pocket_tilt!).
      # spec: ScrewSpec.
      # Cuts into +host_group+. On SU2026 add_circle / pushpull on thin planks
      # can invalidate host; caller decides whether to enable via flag.
      def cut_pocket_and_hole(host_group, geo:, spec:, countersink_first: false, through_hole: true)
        ents     = host_group.entities
        origin   = Geom::Point3d.new(*geo[:origin])
        outward  = Geom::Vector3d.new(*geo[:outward])
        outward.normalize!
        d_cs     = spec.countersink_depth
        r_cs     = spec.countersink_diameter * 0.5
        r_hole   = (spec.shaft_diameter * 0.5) + 0.25.mm
        thick    = geo[:axis_thickness]

        outer = _outer_face_for_box_face(ents, geo)
        return unless outer

        pt0 = _project_point_to_face_plane(origin, outer)

        if countersink_first
          edges_cs = ents.add_circle(pt0, outer.normal, r_cs, 24)
          f_cs = ents.add_face(edges_cs)
          return unless f_cs

          f_cs.reverse! unless f_cs.normal.samedirection?(outward)
          f_cs.pushpull(-d_cs)

          return unless through_hole

          floor  = pt0.offset(outward, -d_cs)
          remain = thick - d_cs + 1.mm
          return if remain <= 0

          floor_face = _face_closest_to_point(ents, floor, outward)
          unless floor_face
            warn '[SU renderer] could not find pocket floor face; countersink only (no through hole)'
            return
          end

          pt1 = _project_point_to_face_plane(floor, floor_face)
          edges_h = ents.add_circle(pt1, floor_face.normal, r_hole, 24)
          f_h = ents.add_face(edges_h)
          return unless f_h

          f_h.reverse! unless f_h.normal.samedirection?(outward)
          f_h.pushpull(-remain)
        else
          # Single through clearance hole (stabler than pocket + bore on SU2026).
          edges_h = ents.add_circle(pt0, outer.normal, r_hole, 24)
          f_h = ents.add_face(edges_h)
          return unless f_h

          f_h.reverse! unless f_h.normal.samedirection?(outward)
          bore = [thick - 2.mm, thick * 0.98].min
          f_h.pushpull(-bore)
        end
      end

      # ── Styling ──────────────────────────────────────────────────────────

      def ensure_layer(name)
        @model.layers[name] || @model.layers.add(name)
      end

      def paint_group(group, rgb, skip_name_re: nil)
        return unless _preview_instance_paint?

        _paint_recursive(group.entities, _ensure_material(rgb), skip_name_re: skip_name_re)
      end

      # Explicit paint path for helper geometry (e.g. cut-plan overlays) that
      # should remain visible even when component-reuse debug mode is active.
      def paint_group_force(group, rgb)
        _paint_recursive(group.entities, _ensure_material(rgb), skip_name_re: nil)
      end

      def debug_paint_axis_faces(root, skip_name_re:)
        return unless @debug_color == :sides

        _direct_render_children(root).each do |child|
          next if skip_name_re&.match?(child.name)

          target_entities =
            case child
            when Sketchup::Group then child.entities
            when Sketchup::ComponentInstance then child.definition.entities
            end
          _paint_box_faces_debug(target_entities) if target_entities
        end
      end

      # Native "Soften/Smooth Edges" equivalent for API-generated geometry.
      # Useful for segmented rounded geometry (e.g. pillows) where hard edge
      # lines between facets should disappear visually.
      def soften_group_edges(group)
        group.entities.grep(Sketchup::Edge).each do |edge|
          next unless edge.valid?
          next unless edge.faces.length == 2

          f1, f2 = edge.faces
          # Keep coplanar top/bottom triangulation hard (avoids the visible
          # diagonal artifact on flat cushion caps). Soften everything else to
          # make the rounded prism read as fully cushioned.
          n1z = f1.normal.z.abs
          n2z = f2.normal.z.abs
          both_horizontal = (n1z >= 0.999) && (n2z >= 0.999)
          is_soft = !both_horizontal
          edge.soft = is_soft
          edge.smooth = is_soft
        end
      end

      # Replaces current group geometry with a fully 3D rounded box.
      def round_group_box_all_edges(group, size:, radius:)
        dx, dy, dz = size.map(&:to_f)
        req = radius.to_f
        return if dx <= 0 || dy <= 0 || dz <= 0 || req <= 0

        max_r = (0.5 * [dx, dy, dz].min) - 0.001.mm.to_f
        r = [req, max_r].min
        return if r <= 1e-9

        ents = group.entities
        existing = ents.to_a.select(&:valid?)
        ents.erase_entities(existing) unless existing.empty?
        _add_full_rounded_box_mesh(ents, 0.0, 0.0, 0.0, dx, dy, dz, r)
        soften_group_edges(group)
      end

      # ── Lifecycle ────────────────────────────────────────────────────────

      def commit(label)
        @model.start_operation(label, true)
        begin
          yield
          @model.commit_operation
        rescue StandardError
          @model.abort_operation
          raise
        end
      end

      def invalidate_view
        @model.active_view.invalidate
      end

      private

      def _add_sharp_prism_z_extrude(entities, x, y, z, dx, dy, dz)
        pts = [
          Geom::Point3d.new(x,      y,      z),
          Geom::Point3d.new(x + dx, y,      z),
          Geom::Point3d.new(x + dx, y + dy, z),
          Geom::Point3d.new(x,      y + dy, z)
        ]
        f = entities.add_face(pts)
        return unless f

        f.reverse! if f.normal.z < 0
        f.pushpull(dz)
      end

      def _add_full_rounded_box_mesh(entities, x, y, z, dx, dy, dz, r)
        x0, y0, z0 = x, y, z
        x1, y1, z1 = x + dx, y + dy, z + dz
        center = Geom::Point3d.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
        xi0, yi0, zi0 = x0 + r, y0 + r, z0 + r
        xi1, yi1, zi1 = x1 - r, y1 - r, z1 - r
        n = FULL_ROUNDED_BOX_SEGMENTS

        # 6 planar center patches.
        _add_quad_grid(
          entities,
          Geom::Point3d.new(xi0, yi0, z0),
          Geom::Point3d.new(xi1, yi0, z0),
          Geom::Point3d.new(xi1, yi1, z0),
          Geom::Point3d.new(xi0, yi1, z0),
          n, n, center
        )
        _add_quad_grid(
          entities,
          Geom::Point3d.new(xi0, yi0, z1),
          Geom::Point3d.new(xi0, yi1, z1),
          Geom::Point3d.new(xi1, yi1, z1),
          Geom::Point3d.new(xi1, yi0, z1),
          n, n, center
        )
        _add_quad_grid(
          entities,
          Geom::Point3d.new(x0, yi0, zi0),
          Geom::Point3d.new(x0, yi1, zi0),
          Geom::Point3d.new(x0, yi1, zi1),
          Geom::Point3d.new(x0, yi0, zi1),
          n, n, center
        )
        _add_quad_grid(
          entities,
          Geom::Point3d.new(x1, yi0, zi0),
          Geom::Point3d.new(x1, yi0, zi1),
          Geom::Point3d.new(x1, yi1, zi1),
          Geom::Point3d.new(x1, yi1, zi0),
          n, n, center
        )
        _add_quad_grid(
          entities,
          Geom::Point3d.new(xi0, y0, zi0),
          Geom::Point3d.new(xi0, y0, zi1),
          Geom::Point3d.new(xi1, y0, zi1),
          Geom::Point3d.new(xi1, y0, zi0),
          n, n, center
        )
        _add_quad_grid(
          entities,
          Geom::Point3d.new(xi0, y1, zi0),
          Geom::Point3d.new(xi1, y1, zi0),
          Geom::Point3d.new(xi1, y1, zi1),
          Geom::Point3d.new(xi0, y1, zi1),
          n, n, center
        )

        # 12 quarter-cylinder edge patches.
        [-1, 1].each do |sy|
          [-1, 1].each do |sz|
            cy = sy.negative? ? yi0 : yi1
            cz = sz.negative? ? zi0 : zi1
            grid = Array.new(n + 1) { Array.new(n + 1) }
            (0..n).each do |i|
              xx = _lerp(xi0, xi1, i.to_f / n)
              (0..n).each do |j|
                a = (j.to_f / n) * (0.5 * Math::PI)
                yy = cy + (sy * r * Math.cos(a))
                zz = cz + (sz * r * Math.sin(a))
                grid[i][j] = Geom::Point3d.new(xx, yy, zz)
              end
            end
            _add_grid_faces(entities, grid, center)
          end
        end
        [-1, 1].each do |sx|
          [-1, 1].each do |sz|
            cx = sx.negative? ? xi0 : xi1
            cz = sz.negative? ? zi0 : zi1
            grid = Array.new(n + 1) { Array.new(n + 1) }
            (0..n).each do |i|
              yy = _lerp(yi0, yi1, i.to_f / n)
              (0..n).each do |j|
                a = (j.to_f / n) * (0.5 * Math::PI)
                xx = cx + (sx * r * Math.cos(a))
                zz = cz + (sz * r * Math.sin(a))
                grid[i][j] = Geom::Point3d.new(xx, yy, zz)
              end
            end
            _add_grid_faces(entities, grid, center)
          end
        end
        [-1, 1].each do |sx|
          [-1, 1].each do |sy|
            cx = sx.negative? ? xi0 : xi1
            cy = sy.negative? ? yi0 : yi1
            grid = Array.new(n + 1) { Array.new(n + 1) }
            (0..n).each do |i|
              zz = _lerp(zi0, zi1, i.to_f / n)
              (0..n).each do |j|
                a = (j.to_f / n) * (0.5 * Math::PI)
                xx = cx + (sx * r * Math.cos(a))
                yy = cy + (sy * r * Math.sin(a))
                grid[i][j] = Geom::Point3d.new(xx, yy, zz)
              end
            end
            _add_grid_faces(entities, grid, center)
          end
        end

        # 8 spherical corner patches.
        [-1, 1].each do |sx|
          [-1, 1].each do |sy|
            [-1, 1].each do |sz|
              cx = sx.negative? ? xi0 : xi1
              cy = sy.negative? ? yi0 : yi1
              cz = sz.negative? ? zi0 : zi1
              grid = Array.new(n + 1) { Array.new(n + 1) }
              (0..n).each do |i|
                a = (i.to_f / n) * (0.5 * Math::PI)
                (0..n).each do |j|
                  b = (j.to_f / n) * (0.5 * Math::PI)
                  xx = cx + (sx * r * Math.cos(a) * Math.cos(b))
                  yy = cy + (sy * r * Math.sin(a) * Math.cos(b))
                  zz = cz + (sz * r * Math.sin(b))
                  grid[i][j] = Geom::Point3d.new(xx, yy, zz)
                end
              end
              _add_grid_faces(entities, grid, center)
            end
          end
        end
      end

      def _add_quad_grid(entities, p00, p10, p11, p01, nu, nv, center)
        grid = Array.new(nu + 1) { Array.new(nv + 1) }
        (0..nu).each do |i|
          u = i.to_f / nu
          (0..nv).each do |j|
            v = j.to_f / nv
            a = _interp_point(p00, p10, u)
            b = _interp_point(p01, p11, u)
            grid[i][j] = _interp_point(a, b, v)
          end
        end
        _add_grid_faces(entities, grid, center)
      end

      def _add_grid_faces(entities, grid, center)
        nu = grid.length - 1
        nv = grid[0].length - 1
        (0...nu).each do |i|
          (0...nv).each do |j|
            p00 = grid[i][j]
            p10 = grid[i + 1][j]
            p11 = grid[i + 1][j + 1]
            p01 = grid[i][j + 1]
            _add_triangle(entities, p00, p10, p11, center)
            _add_triangle(entities, p00, p11, p01, center)
          end
        end
      end

      def _lerp(a, b, t)
        a + ((b - a) * t)
      end

      def _interp_point(p1, p2, t)
        Geom::Point3d.new(
          _lerp(p1.x, p2.x, t),
          _lerp(p1.y, p2.y, t),
          _lerp(p1.z, p2.z, t)
        )
      end

      def _add_triangle(entities, a, b, c, center)
        uniq = [a, b, c].map { |p| [p.x.round(6), p.y.round(6), p.z.round(6)] }.uniq
        return if uniq.length < 3

        f = entities.add_face([a, b, c])
        return unless f

        to_face = Geom::Vector3d.new(
          ((a.x + b.x + c.x) / 3.0) - center.x,
          ((a.y + b.y + c.y) / 3.0) - center.y,
          ((a.z + b.z + c.z) / 3.0) - center.z
        )
        return if to_face.length <= 1e-9

        to_face.normalize!
        n = f.normal.clone
        n.normalize!
        f.reverse! if n.dot(to_face) < 0
      end

      # Clamps requested XY corner radius so quarter-arcs fit inside dx×dy (plan at z).
      def _clamp_plan_corner_radius(dx, dy, requested_r)
        req = requested_r.to_f
        return 0.0 if req <= 0

        max_r = (0.5 * [dx, dy].min) - 0.001.mm.to_f
        return 0.0 if max_r <= 0

        [req, max_r].min
      end

      # Rounded rectangle in cross-section plane, extruded along the part's long axis.
      # Returns true on success.
      def _try_add_rounded_prism_long_axis_extrude(entities, basis, r)
        origin = basis[:origin]
        uaxis = basis[:u_axis]
        vaxis = basis[:v_axis]
        waxis = basis[:w_axis]
        u_len = basis[:u_len]
        v_len = basis[:v_len]
        w_len = basis[:w_len]
        n = ROUNDED_BOX_ARC_SEGMENTS
        p = lambda do |u, v, w = 0.0|
          Geom::Point3d.new(
            origin.x + (uaxis.x * u) + (vaxis.x * v) + (waxis.x * w),
            origin.y + (uaxis.y * u) + (vaxis.y * v) + (waxis.y * w),
            origin.z + (uaxis.z * u) + (vaxis.z * v) + (waxis.z * w)
          )
        end

        edges = []
        edges << entities.add_line(p.call(r, 0), p.call(u_len - r, 0))

        se = entities.add_arc(
          p.call(u_len - r, r),
          uaxis, waxis, r, -0.5 * Math::PI, 0.0, n
        )
        edges.concat(Array(se))

        edges << entities.add_line(p.call(u_len, r), p.call(u_len, v_len - r))

        ne = entities.add_arc(
          p.call(u_len - r, v_len - r),
          uaxis, waxis, r, 0.0, 0.5 * Math::PI, n
        )
        edges.concat(Array(ne))

        edges << entities.add_line(p.call(u_len - r, v_len), p.call(r, v_len))

        nw = entities.add_arc(
          p.call(r, v_len - r),
          uaxis, waxis, r, 0.5 * Math::PI, Math::PI, n
        )
        edges.concat(Array(nw))

        edges << entities.add_line(p.call(0, v_len - r), p.call(0, r))

        sw = entities.add_arc(
          p.call(r, r),
          uaxis, waxis, r, Math::PI, 1.5 * Math::PI, n
        )
        edges.concat(Array(sw))

        chain = edges.flatten.compact
        f = entities.add_face(chain)
        return false unless f

        f.reverse! unless f.normal.samedirection?(waxis)
        f.pushpull(w_len)
        true
      end

      # Chooses a right-handed local frame where +w_axis+ is the requested axis.
      # The rounded rectangle is built in the (u,v) plane and extruded along +w.
      def _basis_for_corner_axis(x, y, z, dx, dy, dz, corner_axis)
        axis = _resolve_corner_axis(corner_axis, dx, dy, dz)
        if axis == :x
          {
            origin: Geom::Point3d.new(x, y, z),
            u_axis: Y_AXIS,
            v_axis: Z_AXIS,
            w_axis: X_AXIS,
            u_len: dy,
            v_len: dz,
            w_len: dx
          }
        elsif axis == :y
          {
            origin: Geom::Point3d.new(x, y, z),
            u_axis: Z_AXIS,
            v_axis: X_AXIS,
            w_axis: Y_AXIS,
            u_len: dz,
            v_len: dx,
            w_len: dy
          }
        else
          {
            origin: Geom::Point3d.new(x, y, z),
            u_axis: X_AXIS,
            v_axis: Y_AXIS,
            w_axis: Z_AXIS,
            u_len: dx,
            v_len: dy,
            w_len: dz
          }
        end
      end

      def _resolve_corner_axis(corner_axis, dx, dy, dz)
        axis = (corner_axis || :long).to_sym
        return axis if %i[x y z].include?(axis)

        dims = { x: dx.to_f, y: dy.to_f, z: dz.to_f }
        sorted = dims.sort_by { |(_, v)| -v }
        axis == :short ? sorted.last[0] : sorted.first[0]
      end

      def _child_entities(parent)
        parent == :root ? @model.entities : parent.entities
      end

      def _direct_render_children(root)
        root.entities.select do |e|
          e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        end
      end

      def _to_geom_transformation(transform)
        m = transform.matrix
        # Geom::Transformation accepts a 16-element column-major array.
        Geom::Transformation.new([
                                   m[0][0], m[1][0], m[2][0], m[3][0],
                                   m[0][1], m[1][1], m[2][1], m[3][1],
                                   m[0][2], m[1][2], m[2][2], m[3][2],
                                   m[0][3], m[1][3], m[2][3], m[3][3]
                                 ])
      end

      def _box_definition(size, corner_radius = 0, corner_axis = :long)
        r = corner_radius.to_f
        axis = (corner_axis || :long).to_sym
        base_key = size.map { |v| v.to_f.round(6) }.join('|')
        key, defn_name =
          if r.abs < 1e-9
            [base_key, "EB::PartBox::#{base_key}"]
          else
            # Version rounded box definition key so geometry-algorithm changes
            # rebuild instead of reusing stale cached definitions in-model.
            rk = "#{base_key}|r#{r.round(6)}|a#{axis}|rv3"
            [rk, "EB::PartBox::#{rk.tr('|', '_')}"]
          end

        cached = @box_definition_cache[key]
        if cached&.valid?
          _clear_face_materials(cached.entities) if _preview_instance_paint?
          return cached
        end

        defn = @model.definitions[defn_name] || @model.definitions.add(defn_name)
        if defn.entities.length.zero?
          add_box(defn, at: [0, 0, 0], size: size, corner_radius: corner_radius, corner_axis: corner_axis)
        end
        # :off preview uses per-instance material; strip stale face paints on shared defs.
        _clear_face_materials(defn.entities) if _preview_instance_paint?
        @box_definition_cache[key] = defn
      end

      def _apply_component_debug_color(instance)
        return unless @debug_color == :components_reuse

        mat = _definition_debug_material(instance.definition)
        _paint_recursive(instance.definition.entities, mat)
      end

      def _definition_debug_material(definition)
        key = definition.name
        cached = @component_debug_material_cache[key]
        return cached if cached&.valid?

        rgb = _stable_rgb_from_key(key)
        mat_name = "SU renderer | def #{key}"
        mat = @model.materials[mat_name] || @model.materials.add(mat_name)
        mat.color = Sketchup::Color.new(rgb[0], rgb[1], rgb[2])
        @component_debug_material_cache[key] = mat
      end

      def _stable_rgb_from_key(key)
        seed = key.to_s.each_byte.reduce(0) { |acc, b| ((acc * 131) + b) & 0xFFFFFFFF }
        r = 120 + (seed & 0x7F)
        g = 120 + ((seed >> 7) & 0x7F)
        b = 120 + ((seed >> 14) & 0x7F)
        [r, g, b]
      end

      def _screw_definition(spec, shaft_length_index)
        l_shaft = spec.shaft_length_at(shaft_length_index)
        key = [
          spec.respond_to?(:name) ? spec.name : 'anon',
          spec.shaft_diameter.to_f.round(6),
          l_shaft.to_f.round(6),
          spec.head_diameter.to_f.round(6),
          spec.head_height.to_f.round(6),
          'sv3'
        ].join('|')

        cached = @screw_definition_cache[key]
        return cached if cached&.valid?

        defn_name = "EB::Screw::#{key}"
        defn = @model.definitions[defn_name] || @model.definitions.add(defn_name)
        defn.set_attribute(@attr_dict, 'ignore_overlaps', true) if @attr_dict
        if defn.entities.length.zero?
          _build_screw_definition_geometry(defn.entities, spec, shaft_length_index)
        end
        # Re-assert screw color on cached definitions that might have been
        # recolored by prior root paint passes in the current SketchUp model.
        _paint_recursive(defn.entities, _ensure_material(SCREW_RGB))
        @screw_definition_cache[key] = defn
      end

      def _build_screw_definition_geometry(ents, spec, shaft_length_index)
        r_shaft = spec.shaft_diameter * 0.5
        l_shaft = spec.shaft_length_at(shaft_length_index)
        r_head  = spec.head_diameter * 0.5
        h_head  = spec.head_height

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

        _paint_recursive(ents, _ensure_material(SCREW_RGB))
      end

      def _outer_face_for_box_face(entities, geo)
        dx, dy, dz = geo[:dx], geo[:dy], geo[:dz]
        tol = 0.75.mm
        case geo[:face_key]
        when :max_z then _pick_face_at_z(entities, dz, tol, Z_AXIS)
        when :min_z then _pick_face_at_z(entities, 0,  tol, Geom::Vector3d.new(0, 0, -1))
        when :max_x then _pick_face_at_x(entities, dx, tol, X_AXIS)
        when :min_x then _pick_face_at_x(entities, 0,  tol, Geom::Vector3d.new(-1, 0, 0))
        when :max_y then _pick_face_at_y(entities, dy, tol, Y_AXIS)
        when :min_y then _pick_face_at_y(entities, 0,  tol, Geom::Vector3d.new(0, -1, 0))
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

      def _face_closest_to_point(entities, point, outward)
        out = outward.clone
        out.normalize!
        entities.grep(Sketchup::Face).select do |f|
          f.valid? && f.normal.samedirection?(out)
        end.min_by { |f| f.bounds.center.distance(point) }
      end

      def _project_point_to_face_plane(pt, face)
        q  = pt.clone
        p0 = face.outer_loop.vertices[0].position
        n  = face.normal.clone
        n.normalize!
        d = (q - p0).dot(n)
        q.offset(n, -d)
      end

      def _paint_box_faces_debug(entities)
        entities.grep(Sketchup::Face).each do |f|
          next unless f.valid?

          key = _classify_axis_face(f.normal)
          next unless key

          mat = _ensure_material(FACE_DEBUG_RGB[key])
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

      def _ensure_material(rgb)
        name = "SU renderer | #{rgb.join(',')}"
        m    = @model.materials[name] || @model.materials.add(name)
        m.color = Sketchup::Color.new(rgb[0], rgb[1], rgb[2])
        m
      end

      # Strip face paints so shared ComponentDefinitions honor each instance's
      # +material+ (legacy preview passes painted definition.entities and leaked color).
      def _clear_face_materials(entities)
        entities.each do |e|
          case e
          when Sketchup::Face
            e.material      = nil
            e.back_material = nil
          when Sketchup::Group
            _clear_face_materials(e.entities)
          when Sketchup::ComponentInstance
            _clear_face_materials(e.definition.entities)
          end
        end
      end

      def _paint_recursive(entities, material, skip_name_re: nil)
        entities.each do |e|
          case e
          when Sketchup::Face
            e.material      = material
            e.back_material = material
          when Sketchup::Group
            next if skip_name_re&.match?(e.name)

            _paint_recursive(e.entities, material, skip_name_re: skip_name_re)
          when Sketchup::ComponentInstance
            next if skip_name_re&.match?(e.name)

            _paint_component_instance(e, material, skip_name_re: skip_name_re)
          end
        end
      end

      # :off / :overlaps — per-instance preview color (shared defs must not carry face materials).
      # :sides / :components_reuse — paint definition faces (see +debug_paint_axis_faces+ /
      #   +_apply_component_debug_color+).
      def _paint_component_instance(instance, material, skip_name_re: nil)
        if _preview_instance_paint?
          instance.material = material
        else
          _paint_recursive(instance.definition.entities, material, skip_name_re: skip_name_re)
        end
      end

      def _preview_instance_paint?
        %i[off overlaps].include?(@debug_color)
      end
    end
  end
end
