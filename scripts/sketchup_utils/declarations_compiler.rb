# frozen_string_literal: true

# Walks a Declarations::DeclarationSet and produces SketchUp geometry.
#
# Each ComponentGroupSpec compiles to exactly one SketchUp ComponentDefinition.
# Leaf geometry (PartSpec / ScrewSpec children) is rendered directly via the
# SketchUpRenderer — no legacy Part object conversion.
# InstanceRef children place ComponentInstances inside a parent definition or
# at the model root (for scenes).
#
# hidden_components on an InstanceRef triggers a derived ComponentDefinition —
# the base group re-compiled with those part IDs excluded — cached by
# (from_id, sorted_hidden_ids) so shared hidden sets share one definition.
#
# floor: true on an InstanceRef lifts the placed instance in +Z until
# bounds.min.z == 0 (needed for upside-down construction-step placements).

require 'set'

module Timmerman
  module SketchupUtils
    class DeclarationsCompiler
      include Declarations

      DECLARATIONS_SCENE_SUFFIX = 'Declarations'.freeze
      DECLARATIONS_GRID_COLS   = 4
      DECLARATIONS_GRID_STEP   = 3000.mm
      # Shift the Declarations grid far to the left so it never overlaps
      # with scene instances which are placed around the world origin.
      DECLARATIONS_X_OFFSET    = -20_000.mm

      # @param decl_set      [Declarations::DeclarationSet]
      # @param renderer      [SketchUpRenderer]
      # @param model         [Sketchup::Model]
      # @param layer         [Sketchup::Layer, nil]
      # @param screw_specs   [Hash{Symbol=>Hardware::ScrewSpec}]
      # @param attr_dict     [String, nil]
      # @param cut_hosts     [Boolean]
      # @param countersink_first [Boolean]
      # @param through_hole  [Boolean]
      # @param corner_radius_for_kind [Hash{Symbol=>Length}]  :beam/:plank/:pillow → radius
      # @param corner_axis_for_kind   [Hash{Symbol=>Symbol}]  :beam/:plank/:pillow → axis
      # @param preview_rgb   [Array(3), nil]  paint color applied to all leaf geometry
      def initialize(decl_set,
                     renderer:,
                     model:,
                     layer: nil,
                     screw_specs: {},
                     attr_dict: nil,
                     cut_hosts: false,
                     countersink_first: false,
                     through_hole: true,
                     corner_radius_for_kind: {},
                     corner_axis_for_kind: {},
                     preview_rgb: nil)
        @decl_set          = decl_set
        @renderer          = renderer
        @model             = model
        @layer             = layer
        @screw_specs       = screw_specs
        @attr_dict         = attr_dict
        @cut_hosts         = cut_hosts
        @countersink_first = countersink_first
        @through_hole      = through_hole
        @cr_kind           = corner_radius_for_kind
        @ca_kind           = corner_axis_for_kind
        @preview_rgb       = preview_rgb

        @compiled      = {}  # spec_id → Sketchup::ComponentDefinition
        @spec_index    = {}  # spec_id → ComponentGroupSpec (for derived-def re-compile)
        @derived_cache = {}  # [from_id, sorted_hidden] → ComponentDefinition
      end

      # ── Lifecycle ─────────────────────────────────────────────────────────────

      # Build all component definitions and scenes. Returns self.
      def compile
        _index_specs(@decl_set.components)

        @renderer.commit("#{@decl_set.prefix}: compile declarations") do
          @decl_set.components.each { |spec| _compile_group(spec) }
        end

        @decl_set.scenes.each { |scene_spec| _compile_scene(scene_spec) }
        _compile_declarations_scene

        self
      end

      # Erase all root-level entities owned by this prefix:
      # - entities whose own name starts with the prefix, OR
      # - ComponentInstances whose definition name starts with the prefix
      #   (scene-placed instances have local names like "BackFrame" but definitions
      #   named "EB | BackFrame").
      def clear
        _exit_edit_context!
        prefix = @decl_set.prefix
        to_erase = @model.entities.select do |e|
          next false unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          e.name.start_with?(prefix) ||
            (e.is_a?(Sketchup::ComponentInstance) && e.definition.name.start_with?(prefix))
        end
        @model.entities.erase_entities(to_erase) unless to_erase.empty?
        @model.definitions.purge_unused
      end

      private

      # ── Indexing ──────────────────────────────────────────────────────────────

      def _index_specs(specs)
        specs.each do |spec|
          @spec_index[spec.id] = spec
          nested = spec.children.select { |c| c.is_a?(ComponentGroupSpec) }
          _index_specs(nested) unless nested.empty?
        end
      end

      # ── Component compilation ─────────────────────────────────────────────────

      def _compile_group(spec)
        return @compiled[spec.id] if @compiled.key?(spec.id)

        # Compile nested inline sub-groups first (depth-first).
        spec.children.select { |c| c.is_a?(ComponentGroupSpec) }.each do |ng|
          _compile_group(ng)
        end

        part_specs  = spec.children.select { |c| c.is_a?(PartSpec) }
        screw_specs = spec.children.select { |c| c.is_a?(ScrewSpec) }
        inst_refs   = spec.children.select { |c| c.is_a?(InstanceRef) }

        full_name = _full_name(spec.id)

        if part_specs.any? || screw_specs.any?
          # Build a temporary root group, render parts/screws directly into it,
          # then convert the whole group to a ComponentDefinition.
          root_group = @renderer.create_group(full_name, parent: :root, layer: @layer)

          # Render each part; keep a name → group map for screw host lookup.
          part_groups = {}
          part_specs.each do |ps|
            r = @cr_kind.fetch(ps.kind, 0)
            # Pillows: create a plain box definition first, then apply full 3D
            # rounding to the definition so every instance that references it
            # automatically gets the rounded geometry.
            is_pillow = ps.kind == :pillow
            g = @renderer.create_part_box(
              ps.id,
              parent:        root_group,
              layer:         @layer,
              size:          ps.size,
              transform:     Transform.translation(ps.at),
              reusable:      !@cut_hosts,
              corner_radius: is_pillow ? 0 : r,
              corner_axis:   @ca_kind.fetch(ps.kind, :long)
            )
            if is_pillow && r > 0 && @renderer.respond_to?(:round_group_box_all_edges)
              defn = g.respond_to?(:definition) ? g.definition : g
              @renderer.round_group_box_all_edges(defn, size: ps.size, radius: r)
            end
            if ps.material && @renderer.respond_to?(:paint_group_force)
              target = g.respond_to?(:definition) ? g.definition : g
              @renderer.paint_group_force(target, ps.material)
            end
            if @attr_dict && ps.note && !ps.note.empty?
              @renderer.set_group_attribute(g, @attr_dict, 'note', ps.note)
            end
            part_groups[ps.id] = g
          end

          # Render each screw using its host group.
          screw_specs.each do |ss|
            host_group = part_groups[ss.host_id]
            unless host_group
              warn "[DeclarationsCompiler] screw '#{ss.id}': host '#{ss.host_id}' not found in #{spec.id}"
              next
            end
            host_ps = part_specs.find { |p| p.id == ss.host_id }
            _render_screw(root_group, host_group, host_ps, ss)
          end

          # Apply preview paint.
          if @preview_rgb
            @renderer.paint_group(root_group, @preview_rgb,
                                  skip_name_re: /\Ascrew\z/)
          end

          # Place InstanceRef children inside the group.
          inst_refs.each do |ref|
            _add_instance_to_entities(root_group.entities, ref)
          end

          ci = @renderer.to_component!(root_group)
          @compiled[spec.id] = ci.definition
          ci.erase!
        else
          # Pure composite: build definition directly, add child instances.
          defn = _find_or_create_definition(full_name)
          inst_refs.each { |ref| _add_instance_to_entities(defn.entities, ref) }
          @compiled[spec.id] = defn
        end

        @compiled[spec.id]
      end

      # Compile a filtered copy of a group with certain part IDs excluded.
      # Cached by (from_id, sorted_hidden_ids).
      def _compile_derived(from_id, hidden_components)
        key = [from_id, hidden_components.sort]
        return @derived_cache[key] if @derived_cache.key?(key)

        base_spec = @spec_index[from_id]
        raise KeyError, "DeclarationsCompiler: unknown component '#{from_id}'" unless base_spec

        hidden_set        = Set.new(hidden_components)
        filtered_children = base_spec.children.reject do |c|
          (c.is_a?(PartSpec)  && hidden_set.include?(c.id)) ||
            (c.is_a?(ScrewSpec) && hidden_set.include?(c.host_id))
        end

        derived_id   = "#{from_id}__hidden_#{hidden_components.sort.join('_')}"
        derived_spec = ComponentGroupSpec.new(id: derived_id, children: filtered_children)
        @spec_index[derived_id] = derived_spec

        defn = _compile_group(derived_spec)
        @derived_cache[key] = defn
      end

      # ── Screw rendering ───────────────────────────────────────────────────────

      # @param root       [Group]    container group (part groups live inside it)
      # @param host_group [Group|ComponentInstance]  the host part entity
      # @param host_ps    [PartSpec, nil]             geometry of the host
      # @param ss         [ScrewSpec]                 declaration
      def _render_screw(root, host_group, host_ps, ss)
        screw_spec = @screw_specs.fetch(ss.spec_id) do
          warn "[DeclarationsCompiler] screw '#{ss.id}': unknown spec_id #{ss.spec_id.inspect}"
          return
        end

        placement = Hardware::ScrewPlacement.new(
          ss.id,
          host_name:                   ss.host_id,
          face:                        ss.face,
          u:                           ss.u,
          v:                           ss.v,
          spec:                        screw_spec,
          shaft_length_index:          ss.shaft_length_index,
          pocket_tilt_from_normal_deg: ss.pocket_tilt_from_normal_deg,
          pocket_tilt_toward:          ss.pocket_tilt_toward,
          pocket_away_from_host:       ss.pocket_away_from_host
        )

        # Build a duck-typed part object with the geometry PartRendering needs.
        host_part = _part_proxy(host_ps)

        PartRendering._render_screw(
          root, host_group, host_part, placement,
          renderer:          @renderer,
          layer:             @layer,
          cut_hosts:         @cut_hosts,
          countersink_first: @countersink_first,
          through_hole:      @through_hole
        )
      rescue StandardError => e
        warn "[DeclarationsCompiler] screw '#{ss.id}': #{e.message}"
      end

      # Minimal duck-typed object satisfying PartRendering._render_screw's
      # host_part requirements: dx/dy/dz (PocketGeometry) + x/y/z (host origin).
      PartProxy = Struct.new(:dx, :dy, :dz, :x, :y, :z)
      private_constant :PartProxy

      def _part_proxy(ps)
        return PartProxy.new(0, 0, 0, 0, 0, 0) unless ps

        PartProxy.new(ps.size[0], ps.size[1], ps.size[2],
                      ps.at[0],   ps.at[1],   ps.at[2])
      end

      # ── Scene compilation ─────────────────────────────────────────────────────

      def _compile_scene(scene_spec)
        scene_name = "#{@decl_set.prefix} | #{scene_spec.id}"
        @renderer.scene(scene_name) do |scope|
          scene_spec.instances.each do |ref|
            ci = _place_at_root(ref)
            scope.track(ci) if ci && scope.respond_to?(:track)
          end
        end
      rescue NoMethodError
        # renderer.scene not available; skip gracefully.
      end

      # Auto-generated "Declarations" scene: one instance of every top-level
      # ComponentGroupSpec laid out in a grid.
      def _compile_declarations_scene
        return unless @model

        specs = @decl_set.components
        return if specs.empty?

        cols = DECLARATIONS_GRID_COLS
        step = DECLARATIONS_GRID_STEP

        scene_name = "#{@decl_set.prefix} | #{DECLARATIONS_SCENE_SUFFIX}"
        @renderer.scene(scene_name) do |scope|
          specs.each_with_index do |spec, idx|
            defn = @compiled[spec.id]
            next unless defn

            col = idx % cols
            row = idx / cols
            t   = Transform.translation([DECLARATIONS_X_OFFSET + col * step, row * step, 0])
            ci  = @model.entities.add_instance(defn, _to_geom(t))
            ci.name  = spec.id
            ci.layer = @layer if @layer

            scope.track(ci) if scope.respond_to?(:track)
          end
        end
      rescue NoMethodError
        # renderer.scene not available; skip.
      end

      # ── Instance placement helpers ────────────────────────────────────────────

      def _add_instance_to_entities(entities, ref)
        defn = _resolve_definition(ref)
        return unless defn

        ci       = entities.add_instance(defn, _to_geom(ref.transform))
        ci.name  = ref.from_id
        ci.layer = @layer if @layer

        _apply_floor_lift(ci) if ref.floor
        ci
      end

      def _place_at_root(ref)
        defn = _resolve_definition(ref)
        return unless defn

        ci       = @model.entities.add_instance(defn, _to_geom(ref.transform))
        ci.name  = ref.from_id
        ci.layer = @layer if @layer

        _apply_floor_lift(ci) if ref.floor
        ci
      end

      def _resolve_definition(ref)
        if ref.hidden_components.any?
          _compile_derived(ref.from_id, ref.hidden_components)
        else
          defn = @compiled[ref.from_id]
          raise KeyError, "DeclarationsCompiler: unknown component '#{ref.from_id}'" unless defn

          defn
        end
      end

      def _apply_floor_lift(ci)
        min_z = ci.bounds.min.z
        return if min_z.abs < 1e-9

        lift = Geom::Transformation.translation([0, 0, -min_z])
        ci.transformation = lift * ci.transformation
      end

      # ── SketchUp helpers ──────────────────────────────────────────────────────

      def _full_name(id)
        "#{@decl_set.prefix} | #{id}"
      end

      def _find_or_create_definition(name)
        @model.definitions[name] || @model.definitions.add(name)
      end

      def _to_geom(transform)
        m = transform.matrix
        Geom::Transformation.new([
                                   m[0][0], m[1][0], m[2][0], m[3][0],
                                   m[0][1], m[1][1], m[2][1], m[3][1],
                                   m[0][2], m[1][2], m[2][2], m[3][2],
                                   m[0][3], m[1][3], m[2][3], m[3][3]
                                 ])
      end

      def _exit_edit_context!
        while @model.close_active; end
      end
    end
  end
end
