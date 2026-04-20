# frozen_string_literal: true

# Generic part value objects used by SketchupUtils::PartCatalog.
# Part classes are pure data — no SketchUp references. A renderer backend
# turns a list of Part objects into scene geometry.
#
# All length/position values are SketchUp length instances (internally in
# inches); use `.mm` literals in call sites.

module Timmerman
  module SketchupUtils
    module Parts
      # ── Part ─────────────────────────────────────────────────────────────
      # Immutable bounding-box geometry with a name + optional note. Acts as
      # both the identity token (name) and the geometric spec (at + size).
      class Part
        attr_reader :name, :at, :size, :note

        # @param at   [Array(Length,Length,Length)] origin of the local AABB.
        # @param size [Array(Length,Length,Length)] dx, dy, dz of the AABB.
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

      # ── Beam ─────────────────────────────────────────────────────────────
      # Rectangular stock prism: two of the three dimensions must match one of
      # the configured +section_sides+ pair (order-independent); the third is
      # the extrusion length (stored as `extrusion_mm`).
      class Beam < Part
        SECTION_TOL_MM = 0.01

        attr_reader :extrusion_mm

        # @param section_sides [Array(Length,Length)] the two stock section sides
        #   (e.g. `[44.mm, 69.mm]`). Extrusion length is the dim that matches
        #   *neither*.
        def initialize(name, at:, size:, section_sides:, note: nil)
          super(name, at: at, size: size, note: note)
          @extrusion_mm = _validate_extrusion(size, section_sides)
        end

        private

        def _validate_extrusion(size, section_sides)
          sides_mm = section_sides.map { |s| s.to_mm.abs }
          is_section = ->(len) { sides_mm.any? { |s| (len.to_mm.abs - s).abs < SECTION_TOL_MM } }
          unless size.count(&is_section) == 2
            got = size.map { |d| format('%.2f mm', d.to_mm) }.join(', ')
            want = sides_mm.map { |s| format('%.2f', s) }.join(' × ')
            raise ArgumentError,
                  "Beam '#{name}': need two section sides (#{want} mm), got (#{got})"
          end

          long = size.find { |d| !is_section.call(d) }
          mm   = long.to_mm.abs
          raise ArgumentError, "Beam '#{name}': extrusion length must be > 0" if mm <= SECTION_TOL_MM

          mm
        end
      end

      # ── Leg ──────────────────────────────────────────────────────────────
      # Vertical post; structurally identical to a Beam but tagged distinctly
      # so consumers (validators, dimension annotators) can filter by type.
      class Leg < Beam; end

      # ── Slat ─────────────────────────────────────────────────────────────
      # Comb tooth; excluded from overlap checks because interleaving is
      # intentional by design.
      class Slat < Beam; end

      # ── Plank ────────────────────────────────────────────────────────────
      # Sheet panel: exactly one of the three dimensions must equal
      # +thickness+. Planks are not tallied against stock bar budgets.
      class Plank < Part
        THICKNESS_TOL_MM = 0.01

        def initialize(name, at:, size:, thickness:, note: nil)
          unless _matches_thickness?(size, thickness, THICKNESS_TOL_MM)
            raise ArgumentError,
                  "Plank '#{name}': one dimension must equal thickness " \
                  "(#{thickness.to_mm} mm), got #{size.map { |d| d.to_mm.round(2) }.inspect}"
          end
          super(name, at: at, size: size, note: note)
        end

        private

        def _matches_thickness?(size, thickness, tol)
          t = thickness.to_mm
          size.any? { |d| (d.to_mm.abs - t).abs < tol }
        end
      end

      # ── Pillow ───────────────────────────────────────────────────────────
      # Foam cushion; exactly one of the three dimensions must equal the
      # short-edge +thickness+. Pillows are cosmetic-only (no overlap check,
      # no stock tally).
      class Pillow < Part
        THICKNESS_TOL_MM = 0.05

        def initialize(name, at:, size:, thickness:, note: nil)
          unless _matches_thickness?(size, thickness, THICKNESS_TOL_MM)
            raise ArgumentError,
                  "Pillow '#{name}': one dimension must equal thickness " \
                  "(#{thickness.to_mm} mm), got #{size.map { |d| d.to_mm.round(2) }.inspect}"
          end
          super(name, at: at, size: size, note: note)
        end

        private

        def _matches_thickness?(size, thickness, tol)
          t = thickness.to_mm
          size.any? { |d| (d.to_mm.abs - t).abs < tol }
        end
      end
    end
  end
end
