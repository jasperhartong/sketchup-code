# frozen_string_literal: true

# Generic declarative DSL for SketchUp geometry.
#
# Usage:
#
#   spec = Timmerman::SketchupUtils::SpecBuilder.build(prefix: "MyProject") do
#     component_group(id: "Shelf") do
#       part(id: "top", kind: :plank, size: [800.mm, 300.mm, 18.mm], at: [0, 0, 0])
#       part(id: "left_leg", kind: :beam, size: [44.mm, 44.mm, 400.mm], at: [0, 0, 0])
#     end
#     component_group(id: "Assembly") do
#       instance(from_id: "Shelf", at: [0, 0, 0])
#     end
#     scene(id: "overview") do
#       instance(from_id: "Assembly", at: [0, 0, 0])
#     end
#   end
#
# The block is a plain Ruby closure: local variables from the outer scope
# (e.g. `config`) are fully accessible inside it.
#
# PartSpec kinds:
#   :beam   — rectangular stock prism (beams, legs, slats, posts — all the same geometry)
#   :plank  — sheet panel
#   :pillow — foam cushion
#   :screw  — hardware placement (uses different geometry props; see ScrewSpec)
#
# instance() accepts:
#   transform:  [Transform]  full 4x4 transform (required unless `at:` is given)
#   at:         [Array(3)]   shorthand for Transform.translation([x,y,z])
#   floor:      [Boolean]    if true, compiler lifts the placed instance in +Z
#                            until its bounding-box min.z == 0 (use for flipped
#                            upside-down placements where you know the bottom
#                            depends on bounds computed at render time)
#   hidden_components: [Array<String>]  part IDs to suppress in this instance
#                            (compiler creates a derived ComponentDefinition
#                             keyed by from_id + sorted hidden set)

module Timmerman
  module SketchupUtils
    module Declarations
      # ── Value objects ────────────────────────────────────────────────────────

      # A single geometry primitive within a component group.
      # kind: :beam | :plank | :pillow
      PartSpec = Struct.new(:id, :kind, :size, :at, :note, :comb, keyword_init: true)

      # A hardware placement within a component group.
      # host_id references the id of a PartSpec in the same component group.
      ScrewSpec = Struct.new(
        :id, :host_id, :face, :u, :v, :spec_id,
        :shaft_length_index, :pocket_tilt_from_normal_deg,
        :pocket_tilt_toward, :pocket_away_from_host,
        keyword_init: true
      )

      # A reference to a declared component group, placed at a transform.
      # floor: true → compiler auto-lifts in +Z so bounding-box min.z == 0.
      InstanceRef = Struct.new(
        :from_id, :transform, :floor, :hidden_components,
        keyword_init: true
      )

      # A named reusable group of parts/instances.
      ComponentGroupSpec = Struct.new(:id, :children, keyword_init: true)

      # A named scene composed of instances placed in the model root.
      SceneSpec = Struct.new(:id, :instances, keyword_init: true)

      # Top-level container returned by SpecBuilder.build.
      DeclarationSet = Struct.new(:prefix, :components, :scenes, keyword_init: true)

      # ── ComponentGroupBuilder ─────────────────────────────────────────────────

      class ComponentGroupBuilder
        def initialize
          @children = []
        end

        # Leaf geometry part. kind: :beam | :plank | :pillow
        def part(id:, kind:, size:, at:, note: nil, comb: false)
          @children << PartSpec.new(
            id: id.to_s, kind: kind,
            size: size, at: at,
            note: note, comb: comb
          )
        end

        # Hardware screw placement referencing a sibling part by id.
        def screw(id:, host_id:, face:, u:, v:, spec_id:,
                  shaft_length_index: 0,
                  pocket_tilt_from_normal_deg: 0,
                  pocket_tilt_toward: :pos_v,
                  pocket_away_from_host: false)
          @children << ScrewSpec.new(
            id: id.to_s, host_id: host_id.to_s,
            face: face, u: u, v: v, spec_id: spec_id,
            shaft_length_index: shaft_length_index,
            pocket_tilt_from_normal_deg: pocket_tilt_from_normal_deg,
            pocket_tilt_toward: pocket_tilt_toward,
            pocket_away_from_host: pocket_away_from_host
          )
        end

        # Place another declared component group inside this one.
        # Accepts either `transform:` (a Transform object) or `at:` (shorthand
        # for a pure translation).
        def instance(from_id:, transform: nil, at: nil, floor: false,
                     hidden_components: [])
          t = _resolve_transform(transform, at)
          @children << InstanceRef.new(
            from_id: from_id.to_s,
            transform: t,
            floor: floor,
            hidden_components: hidden_components.map(&:to_s)
          )
        end

        # Nest a sub-group inline (compiles to its own ComponentDefinition).
        def component_group(id:, &block)
          builder = ComponentGroupBuilder.new
          builder.instance_eval(&block) if block
          @children << ComponentGroupSpec.new(id: id.to_s, children: builder._children)
        end

        def _children = @children.freeze

        private

        def _resolve_transform(transform, at)
          if transform
            raise ArgumentError, 'instance: pass transform: OR at:, not both' if at
            return transform
          end
          raise ArgumentError, 'instance: transform: or at: is required' unless at

          Transform.translation(at)
        end
      end

      # ── SceneBuilder ──────────────────────────────────────────────────────────

      class SceneBuilder
        def initialize
          @instances = []
        end

        def instance(from_id:, transform: nil, at: nil, floor: false,
                     hidden_components: [])
          t = _resolve_transform(transform, at)
          @instances << InstanceRef.new(
            from_id: from_id.to_s,
            transform: t,
            floor: floor,
            hidden_components: hidden_components.map(&:to_s)
          )
        end

        def _instances = @instances.freeze

        private

        def _resolve_transform(transform, at)
          if transform
            raise ArgumentError, 'instance: pass transform: OR at:, not both' if at
            return transform
          end
          raise ArgumentError, 'instance: transform: or at: is required' unless at

          Transform.translation(at)
        end
      end

      # ── SpecBuilder ───────────────────────────────────────────────────────────

      # Top-level builder. Provides component_group and scene in one block.
      class SpecBuilder
        def initialize(prefix)
          @prefix     = prefix
          @components = []
          @scenes     = []
        end

        def self.build(prefix:, &block)
          builder = new(prefix)
          builder.instance_eval(&block) if block
          builder._build
        end

        def component_group(id:, &block)
          b = ComponentGroupBuilder.new
          b.instance_eval(&block) if block
          @components << ComponentGroupSpec.new(id: id.to_s, children: b._children)
        end

        def scene(id:, &block)
          b = SceneBuilder.new
          b.instance_eval(&block) if block
          @scenes << SceneSpec.new(id: id.to_s, instances: b._instances)
        end

        def _build
          DeclarationSet.new(
            prefix:     @prefix,
            components: @components.freeze,
            scenes:     @scenes.freeze
          )
        end
      end
    end
  end
end
