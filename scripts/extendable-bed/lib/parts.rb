# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # ── Part value objects ──────────────────────────────────────────────────────
    #
    # Parts are *descriptions* of geometry — plain Ruby structs that hold a name,
    # position, size, and optional note. The SketchUpRenderer (renderer.rb) turns
    # them into actual SketchUp groups.
    #
    # Every Part is immutable once constructed.

    class Part
      attr_reader :name, :at, :size, :note
      # at:   [x, y, z]       — origin of the bounding box in parent local space
      # size: [dx, dy, dz]    — dimensions of the bounding box

      def initialize(name, at:, size:, note: nil)
        @name = name.to_s.freeze
        @at   = at.freeze
        @size = size.freeze
        @note = note&.to_s&.freeze
      end

      def x  = @at[0]
      def y  = @at[1]
      def z  = @at[2]
      def dx = @size[0]
      def dy = @size[1]
      def dz = @size[2]

      def to_s
        format('%s  @[%.1f, %.1f, %.1f]  size[%.1f×%.1f×%.1f]',
               name, x.to_mm, y.to_mm, z.to_mm, dx.to_mm, dy.to_mm, dz.to_mm)
      end
    end

    # ── Beam ───────────────────────────────────────────────────────────────────
    # A 44×69 mm stock beam prism.  Two of the three dimensions must match the
    # section sides (order doesn't matter); the third is the extrusion length.
    # Validation requires a Config so that section tolerances are consistent.

    class Beam < Part
      attr_reader :extrusion_mm   # length along the extrusion axis, in mm

      def initialize(name, at:, size:, config:, note: nil)
        super(name, at: at, size: size, note: note)
        @extrusion_mm = config.extrusion_length_mm(size[0], size[1], size[2])
      end
    end

    # ── Leg ────────────────────────────────────────────────────────────────────
    # A vertical post; structurally a Beam but semantically distinct so the
    # Validator and Dimensions classes can filter on type.

    class Leg < Beam; end

    # ── Slat ───────────────────────────────────────────────────────────────────
    # A comb tooth (back or front).  Slats are excluded from AABB overlap checks
    # because interleaving is intentional by design.

    class Slat < Beam; end

    # ── Plank ──────────────────────────────────────────────────────────────────
    # A thin sheet panel (18 mm stock).  The narrow dimension is always
    # Config#plank_thickness; the other two are the face dimensions.
    # Planks are not tallied against the beam stock-length budget.

    class Plank < Part
      def initialize(name, at:, size:, config:, note: nil)
        unless _has_plank_thickness?(size, config)
          raise ArgumentError,
                "Plank '#{name}': one dimension must equal plank_thickness " \
                "(#{config.plank_thickness.to_mm} mm), got #{size.map { |d| d.to_mm.round(2) }.inspect}"
        end

        super(name, at: at, size: size, note: note)
      end

      private

      def _has_plank_thickness?(size, config)
        t   = config.plank_thickness.to_mm
        tol = 0.01
        size.any? { |d| (d.to_mm.abs - t).abs < tol }
      end
    end

    # ── Pillow ─────────────────────────────────────────────────────────────────
    # A foam cushion prism.  Exactly one dimension must equal Config#pillow_thickness
    # (the short edge of the foam block).  Pillows are cosmetic-only and are neither
    # validated for overlaps nor tallied in the stock plan.

    class Pillow < Part
      def initialize(name, at:, size:, config:, note: nil)
        unless _has_pillow_thickness?(size, config)
          raise ArgumentError,
                "Pillow '#{name}': one dimension must equal pillow_thickness " \
                "(#{config.pillow_thickness.to_mm} mm), got #{size.map { |d| d.to_mm.round(2) }.inspect}"
        end

        super(name, at: at, size: size, note: note)
      end

      private

      def _has_pillow_thickness?(size, config)
        t   = config.pillow_thickness.to_mm
        tol = 0.05
        size.any? { |d| (d.to_mm.abs - t).abs < tol }
      end
    end
  end
end
