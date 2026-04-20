# frozen_string_literal: true

# Backend-agnostic catalog of Part value objects, built through a tiny DSL.
# Subclasses implement `#assemble` and use the DSL (`beam`, `leg`, `slat`,
# `plank`, `pillow`, `screw`) to populate `@parts` + `@hardware`. Once built,
# a catalog is immutable: consumers filter it through `#view(exclude:)` for
# per-render subsets.

module Timmerman
  module SketchupUtils
    class PartCatalog
      attr_reader :parts, :hardware

      # @param section_sides    [Array(Length,Length)] passed to every beam/leg/slat
      # @param plank_thickness  [Length]               passed to every plank
      # @param pillow_thickness [Length]               passed to every pillow
      # @param screw_specs      [Hash{Symbol=>ScrewSpec}] resolved by `screw spec_id:`
      def initialize(section_sides:, plank_thickness:, pillow_thickness:, screw_specs: {})
        @section_sides   = section_sides
        @plank_thickness = plank_thickness
        @pillow_thickness = pillow_thickness
        @screw_specs     = screw_specs
        @parts           = []
        @hardware        = []
        assemble
        _freeze_all
      end

      # Subclasses MUST implement.
      def assemble
        raise NotImplementedError, "#{self.class}#assemble is not implemented"
      end

      # ── Lookup / iteration ─────────────────────────────────────────────

      def names = @parts.map(&:name)

      def part(name)
        @parts.find { |p| p.name == name } ||
          raise(KeyError, "Part not found: #{name.inspect}")
      end

      # Returns a View over the catalog that hides any part whose name is in
      # +exclude+. Hardware whose +host_name+ is hidden is also filtered out.
      # +group_name+ is the Outliner root name for the preview that renders
      # this view (plain catalogs have no preview-specific name).
      def view(group_name:, exclude: [])
        View.new(self, group_name: group_name, excluded_names: Set.new(exclude.map(&:to_s)))
      end

      # ── DSL primitives (call from #assemble) ───────────────────────────

      def beam(name, at:, size:, note: nil)
        @parts << Parts::Beam.new(name, at: at, size: size, section_sides: @section_sides, note: note)
      end

      def leg(name, at:, size:, note: nil)
        @parts << Parts::Leg.new(name, at: at, size: size, section_sides: @section_sides, note: note)
      end

      def slat(name, at:, size:, note: nil)
        @parts << Parts::Slat.new(name, at: at, size: size, section_sides: @section_sides, note: note)
      end

      def plank(name, at:, size:, note: nil)
        @parts << Parts::Plank.new(name, at: at, size: size, thickness: @plank_thickness, note: note)
      end

      def pillow(name, at:, size:, note: nil)
        @parts << Parts::Pillow.new(name, at: at, size: size, thickness: @pillow_thickness, note: note)
      end

      def screw(name, host_name:, face:, u:, v:, spec_id:, shaft_length_index: 0,
                pocket_tilt_from_normal_deg: 0, pocket_tilt_toward: :pos_v,
                pocket_away_from_host: false)
        spec = @screw_specs.fetch(spec_id) do
          raise KeyError, "unknown screw spec #{spec_id.inspect}"
        end
        @hardware << Hardware::ScrewPlacement.new(
          name,
          host_name: host_name, face: face, u: u, v: v, spec: spec,
          shaft_length_index: shaft_length_index,
          pocket_tilt_from_normal_deg: pocket_tilt_from_normal_deg,
          pocket_tilt_toward: pocket_tilt_toward,
          pocket_away_from_host: pocket_away_from_host
        )
      end

      private

      def _freeze_all
        @parts.freeze
        @hardware.freeze
      end

      # Read-only filtered projection of a catalog. Same shape as a catalog
      # (.parts, .hardware) plus +group_name+ so renderers can use it directly.
      class View
        attr_reader :group_name

        def initialize(catalog, group_name:, excluded_names:)
          @catalog        = catalog
          @group_name     = group_name.to_s
          @excluded_names = excluded_names
        end

        def parts
          @catalog.parts.reject { |p| @excluded_names.include?(p.name) }
        end

        def hardware
          @catalog.hardware.reject { |h| @excluded_names.include?(h.host_name) }
        end

        def names = parts.map(&:name)
      end
    end
  end
end

require 'set'
