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

      # @param attr_dict [String] SketchUp attribute-dictionary name used for
      #   per-group notes (so parts round-trip with their provenance comment).
      def initialize(model, attr_dict:, debug_color: :off)
        @model             = model
        @attr_dict         = attr_dict
        @debug_color = debug_color.to_sym
        @box_definition_cache = {}
        @screw_definition_cache = {}
        @component_debug_material_cache = {}
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
      def create_part_box(name, parent:, layer:, size:, transform:, reusable: true)
        unless reusable
          g = create_group(name, parent: parent, layer: layer)
          add_box(g, at: [0, 0, 0], size: size)
          set_group_transform(g, transform)
          return g
        end

        definition = _box_definition(size)
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

      def group_min_z(group) = group.bounds.min.z

      # ── Geometry primitives ─────────────────────────────────────────────

      def add_box(group, at:, size:)
        x,  y,  z  = at
        dx, dy, dz = size
        pts = [
          Geom::Point3d.new(x,      y,      z),
          Geom::Point3d.new(x + dx, y,      z),
          Geom::Point3d.new(x + dx, y + dy, z),
          Geom::Point3d.new(x,      y + dy, z)
        ]
        f = group.entities.add_face(pts)
        f.reverse! if f.normal.z < 0
        f.pushpull(dz)
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

      def paint_group(group, rgb)
        return if @debug_color == :components_reuse

        _paint_recursive(group.entities, _ensure_material(rgb))
      end

      # Explicit paint path for helper geometry (e.g. cut-plan overlays) that
      # should remain visible even when component-reuse debug mode is active.
      def paint_group_force(group, rgb)
        _paint_recursive(group.entities, _ensure_material(rgb))
      end

      def paint_named_children(root, names, rgb)
        return if names.nil? || names.empty?
        return if @debug_color == :components_reuse

        mat = _ensure_material(rgb)
        Array(names).each do |name|
          child = _named_child(root, name)
          next unless child

          child_entities =
            case child
            when Sketchup::Group then child.entities
            when Sketchup::ComponentInstance then child.definition.entities
            end
          _paint_recursive(child_entities, mat) if child_entities
        end
      end

      def hide_named_children(root, names, hidden: true)
        return if names.nil? || names.empty?

        Array(names).each do |name|
          child = _named_child(root, name)
          child.hidden = hidden if child
        end
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

      def _child_entities(parent)
        parent == :root ? @model.entities : parent.entities
      end

      def _direct_render_children(root)
        root.entities.select do |e|
          e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        end
      end

      def _named_child(root, name)
        _direct_render_children(root).find { |c| c.name == name }
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

      def _box_definition(size)
        key = size.map { |v| v.to_f.round(6) }.join('|')
        cached = @box_definition_cache[key]
        return cached if cached&.valid?

        defn_name = "EB::PartBox::#{key}"
        defn = @model.definitions[defn_name] || @model.definitions.add(defn_name)
        if defn.entities.length.zero?
          add_box(defn, at: [0, 0, 0], size: size)
        end
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
          spec.head_height.to_f.round(6)
        ].join('|')

        cached = @screw_definition_cache[key]
        return cached if cached&.valid?

        defn_name = "EB::Screw::#{key}"
        defn = @model.definitions[defn_name] || @model.definitions.add(defn_name)
        if defn.entities.length.zero?
          _build_screw_definition_geometry(defn.entities, spec, shaft_length_index)
        end
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

        _paint_recursive(ents, _ensure_material([168, 172, 180]))
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
