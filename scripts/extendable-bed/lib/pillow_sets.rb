# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Per-mode pillow catalogs. Pillows vary structurally with
    # +pillow_mode+ (the cushion arrangement for a given bed state), so there
    # is one catalog instance per (mode, foot_world_y) combination — created
    # once per preview and then rendered through the standard PartRendering
    # driver, same as any other part.
    #
    # Modes (IKEA mattress set: 1 big + 2 small):
    #   :extended           — big flat on back + two small flats on front
    #   :extended_one_small — 1 small flat extending front + 1 stacked upright on big at head
    #   :retracted          — big flat + two-layer couch stack at head
    #   :retracted_gnd      — big flat; two smalls laid flat on floor at head
    #   nil                 — no pillows
    module PillowSets
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
          _big_pillow('Ext1; big flat on slats; one small stacked upright at head.')
          sm = c.pillow_small_length
          return unless sm.positive?

          t = c.pillow_thickness
          pillow 'EB | pillow | small | 2',
                 at:   [0, y_pillow, c.z_slat_top + t],
                 size: [c.outer_width, t, sm],
                 note: 'Ext1; small | 2 upright on big at head (small | 1 extends front).'
        end

        def _retracted_back
          _big_pillow('Retracted / couch seat; flat on slats; Y span = pillow_big_length.')
          sm = c.pillow_small_length
          return unless sm.positive?

          t = c.pillow_thickness
          z = c.z_slat_top + t
          pillow 'EB | pillow | small | 1',
                 at:   [0, y_pillow, z],
                 size: [c.outer_width, t, sm],
                 note: 'Couch; small | 1 vertical slab on big pillow; w×t×sm in X×Y×Z.'
          pillow 'EB | pillow | small | 2',
                 at:   [0, y_pillow + t, z],
                 size: [c.outer_width, t, sm],
                 note: 'Couch back cushion; small | 2 vertical at Y0 = y_pillow + t.'
        end

        def _retracted_gnd_back
          _big_pillow('Retracted; big on slats. Smalls stored on floor.')
          sm = c.pillow_small_length
          return unless sm.positive?

          pad           = c.slat_gap
          y_head        = -c.plank_thickness
          mid_y0_val    = (c.length_retracted - c.leg_x) + c.plank_thickness + c.mid_layout_y_shift
          y_post_head   = y_head + c.beam_wide + c.leg_y + pad
          y_inset_legs  = y_head + c.leg_y + pad
          y_corridor_lo = [y_inset_legs, y_post_head].max
          y_corridor_hi = mid_y0_val - pad
          total_sm      = c.small_pillow_count * sm
          avail         = y_corridor_hi - y_corridor_lo
          y_cluster     = if avail >= total_sm
                            y_corridor_lo + ((avail - total_sm) / 2.0)
                          else
                            y_corridor_lo
                          end
          y_under_shift = 20.mm

          c.small_pillow_count.times do |i|
            y = y_cluster + ((c.small_pillow_count - 1 - i) * sm) - y_under_shift
            pillow "EB | pillow | small | #{i + 1}",
                   at:   [0, y, 0],
                   size: [c.outer_width, sm, c.pillow_thickness],
                   note: "Retracted+stored; small #{i + 1}/#{c.small_pillow_count} on floor; flush with frame sides; Y clears posts; shifted −Y 20 mm."
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

          c.small_pillow_count.times do |i|
            # Pillows ordered foot→head (index 0 = SMALL_1 is most footward).
            y_world = y_small_head_world + ((c.small_pillow_count - 1 - i) * sm)
            pillow "EB | pillow | small | #{i + 1}",
                   at:   [0, y_world - @foot_world_y, c.z_slat_top],
                   size: [c.outer_width, sm, c.pillow_thickness],
                   note: "Extended; small #{i + 1}/#{c.small_pillow_count}; equal share of extension gap."
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
