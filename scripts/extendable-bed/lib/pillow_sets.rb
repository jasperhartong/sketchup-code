# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Per-mode pillow catalogs. Pillows vary structurally with
    # +pillow_mode+ (the cushion arrangement for a given bed state), so there
    # is one catalog instance per (mode, foot_world_y) combination — created
    # once per preview and then rendered through the standard PartRendering
    # driver, same as any other part.
    #
    # Modes (IKEA mattress set: 1 big + 3 small):
    #   :extended           — big flat on back + three small flats on front (foot→head: 3, 1, 2)
    #   :extended_one_small — 1 small flat on front + upright 2 and 3 stacked on big at head
    #   :retracted          — big flat; small | 1 upright at head; | 2 along +X outer edge; | 3 under slats
    #   :retracted_gnd      — big flat; three smalls flat on floor at head (3, 1, 2)
    #   nil                 — no pillows
    module PillowSets
      # Foot→head order for small-pillow names in the extension gap / under-bed storage.
      FOOT_TO_HEAD_SMALL_NUMBERS = [3, 1, 2].freeze
      # ── BackPillowSet ─────────────────────────────────────────────────────
      # Pillows rendered inside the back root group (back-frame local space).
      class BackPillowSet < SketchupUtils::PartCatalog
        attr_reader :mode

        def initialize(config, mode:)
          @config = config
          @mode   = mode
          super(
            section_sides:    [config.beam_narrow, config.beam_wide],
            plank_thickness:  config.plank_thickness,
            pillow_thickness: config.pillow_thickness,
            screw_specs:      config.screw_specs
          )
        end

        def assemble
          case @mode
          when :extended           then _extended_back
          when :extended_one_small then _extended_one_small_back
          when :retracted          then _retracted_back
          when :retracted_gnd      then _retracted_gnd_back
          when nil                 then # no pillows
          else
            raise ArgumentError, "Unknown pillow_mode #{@mode.inspect}"
          end
        end

        private

        def c = @config

        # Y origin shared by big pillow and all couch stacks. Zero for default
        # config (beam_y == beam_narrow); kept as a formula for other configs.
        def y_pillow = c.beam_y - c.beam_narrow

        # Head-side cluster for smalls stored flat on the floor (same anchor as :retracted_gnd).
        def _head_small_storage_y0 = -c.plank_thickness + c.beam_narrow + c.leg_y

        def _big_pillow(note)
          pillow 'EB | pillow | big',
                 at:   [0, y_pillow, c.z_slat_top],
                 size: [c.outer_width, c.pillow_big_length, c.pillow_thickness],
                 note: note
        end

        def _extended_back
          _big_pillow('Extended bed; on slats between planks; +Y flush head plank.')
        end

        def _extended_one_small_back
          _big_pillow('Ext1; big flat on slats; upright smalls stacked at head.')
          sm = c.pillow_small_length
          return unless sm.positive?

          t = c.pillow_thickness
          z = c.z_slat_top + t
          pillow 'EB | pillow | small | 2',
                 at:   [0, y_pillow, z],
                 size: [c.outer_width, t, sm],
                 note: 'Ext1; small | 2 upright on big (small | 1 extends front).'
          pillow 'EB | pillow | small | 3',
                 at:   [0, y_pillow + t, z],
                 size: [c.outer_width, t, sm],
                 note: 'Ext1; small | 3 upright in front of small | 2 (same orientation as retracted couch).'
        end

        def _retracted_back
          _big_pillow('Retracted / couch seat; flat on slats; Y span = pillow_big_length.')
          sm = c.pillow_small_length
          return unless sm.positive?

          t = c.pillow_thickness
          z = c.z_slat_top + t
          pillow 'EB | pillow | small | 3',
                 at:   [0, _head_small_storage_y0, 0],
                 size: [c.outer_width, sm, c.pillow_thickness],
                 note: 'Couch; small | 3 flat under slats at head (foot storage).'
          pillow 'EB | pillow | small | 1',
                 at:   [0, y_pillow, z],
                 size: [c.outer_width, t, sm],
                 note: 'Couch; small | 1 upright at head (+Y foot of stack).'
          pillow 'EB | pillow | small | 2',
                 at:   [c.outer_width - t, y_pillow + t, z],
                 size: [t, c.outer_width, sm],
                 note: 'Couch; small | 2 along +X outer edge; wide face flush bed side; +Y flush small | 1.'
        end

        def _retracted_gnd_back
          _big_pillow('Retracted; big on slats. Smalls stored on floor.')
          sm = c.pillow_small_length
          return unless sm.positive?

          y_cluster = _head_small_storage_y0

          FOOT_TO_HEAD_SMALL_NUMBERS.each_with_index do |n, idx|
            y = y_cluster + (idx * sm)
            pillow "EB | pillow | small | #{n}",
                   at:   [0, y, 0],
                   size: [c.outer_width, sm, c.pillow_thickness],
                   note: "Retracted+stored; small | #{n} (#{idx + 1}/3 foot→head); head flush behind-head +X post max_y."
          end
        end
      end

      # ── FrontPillowSet ────────────────────────────────────────────────────
      # Pillows rendered inside the front root group. All Y coords are front-frame
      # local (world Y − foot_world_y).
      class FrontPillowSet < SketchupUtils::PartCatalog
        attr_reader :mode, :foot_world_y

        def initialize(config, mode:, foot_world_y:)
          @config       = config
          @mode         = mode
          @foot_world_y = foot_world_y
          super(
            section_sides:    [config.beam_narrow, config.beam_wide],
            plank_thickness:  config.plank_thickness,
            pillow_thickness: config.pillow_thickness,
            screw_specs:      config.screw_specs
          )
        end

        def assemble
          case @mode
          when :extended           then _extended_front
          when :extended_one_small then _extended_one_small_front
          when :retracted, :retracted_gnd, nil
            # No front pillows in these modes.
          else
            raise ArgumentError, "Unknown pillow_mode #{@mode.inspect}"
          end
        end

        private

        def c = @config

        def y_pillow = c.beam_y - c.beam_narrow
        def y_small_head_world = y_pillow + c.pillow_big_length

        def _extended_front
          sm = c.pillow_small_length
          return unless sm.positive?

          FOOT_TO_HEAD_SMALL_NUMBERS.each_with_index do |n, idx|
            y_world = y_small_head_world + (idx * sm)
            pillow "EB | pillow | small | #{n}",
                   at:   [0, y_world - @foot_world_y, c.z_slat_top],
                   size: [c.outer_width, sm, c.pillow_thickness],
                   note: "Extended; small | #{n} (#{idx + 1}/3 foot→head); fills extension gap."
          end
        end

        def _extended_one_small_front
          sm = c.pillow_small_length
          return unless sm.positive?

          pillow 'EB | pillow | small | 1',
                 at:   [0, y_small_head_world - @foot_world_y, c.z_slat_top],
                 size: [c.outer_width, sm, c.pillow_thickness],
                 note: 'Ext1; one flat extends frame (foot = retracted + one small).'
        end
      end
    end
  end
end
