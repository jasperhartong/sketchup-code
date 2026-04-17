# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # A matched back + front frame at a specific world position, plus the pillows
    # that belong to this configuration (extended / halfway / retracted / stored).
    #
    # +pillow_mode+ controls which cushion arrangement is generated:
    #   :extended       — big flat + three small flats (bed fully open)
    #   :extended_one_small — 3 smalls total: 1 flat extends frame + 2 stacked on big at head (cf. retracted)
    #   :halfway        — big flat + couch head + two small flats on front frame
    #   :retracted      — big flat + couch stack (small|3 / head / right)
    #   :retracted_gnd  — big flat on slats, three smalls stored on the floor
    #   nil             — no pillows
    class BedPair
      attr_reader :back_name, :front_name, :offset_x, :pair_row_y, :foot_world_y,
                  :pillow_mode, :tally_stock,
                  :back_highlight_part_names, :front_highlight_part_names,
                  :back_only_part_names, :front_only_part_names,
                  :omit_under_slat_foot_end_beam, :omit_head_ledge_plank, :omit_foot_ledge_plank,
                  :omit_head_cap_beam, :omit_foot_cap_beam,
                  :omit_back_outer_sisters_and_ties,
                  :omit_legs, :omit_head_outer_corner_legs, :omit_foot_outer_corner_legs,
                  :upside_down

      # Construction-step row: +variant+ selects `omit_*` flags (see `BedPairCatalog::VARIANT_OMITS`)
      # and an optional per-frame part whitelist (see `BedPairCatalog::VARIANT_ONLY_PART_NAMES`).
      def self.from_assembly_row(config, variant:, **kwargs)
        omits     = BedPairCatalog.omit_flags_for_variant(variant)
        whitelist = BedPairCatalog.only_part_names_for_variant(variant, config)
        new(config, **omits, **whitelist, **kwargs)
      end

      def initialize(config,
                     back_name:,
                     front_name:,
                     offset_x:,
                     foot_world_y:,
                     pair_row_y: 0,
                     pillow_mode: nil,
                     tally_stock: true,
                     omit_under_slat_foot_end_beam: false,
                     omit_head_ledge_plank: false,
                     omit_foot_ledge_plank: false,
                     omit_head_cap_beam: false,
                     omit_foot_cap_beam: false,
                     omit_back_outer_sisters_and_ties: false,
                     omit_legs: false,
                     omit_head_outer_corner_legs: false,
                     omit_foot_outer_corner_legs: false,
                     back_highlight_part_names: [],
                     front_highlight_part_names: [],
                     back_only_part_names: nil,
                     front_only_part_names: nil,
                     upside_down: false)
        @config       = config
        @back_name    = back_name
        @front_name   = front_name
        @offset_x     = offset_x
        @pair_row_y   = pair_row_y
        @foot_world_y = foot_world_y
        @pillow_mode  = pillow_mode
        @tally_stock  = tally_stock
        @omit_under_slat_foot_end_beam = omit_under_slat_foot_end_beam
        @omit_head_ledge_plank        = omit_head_ledge_plank
        @omit_foot_ledge_plank        = omit_foot_ledge_plank
        @omit_head_cap_beam           = omit_head_cap_beam
        @omit_foot_cap_beam           = omit_foot_cap_beam
        @omit_back_outer_sisters_and_ties = omit_back_outer_sisters_and_ties
        @omit_legs                    = omit_legs
        @omit_head_outer_corner_legs  = omit_head_outer_corner_legs
        @omit_foot_outer_corner_legs  = omit_foot_outer_corner_legs
        @back_highlight_part_names    = back_highlight_part_names
        @front_highlight_part_names   = front_highlight_part_names
        @back_only_part_names         = back_only_part_names
        @front_only_part_names        = front_only_part_names
        @upside_down                  = upside_down
      end

      def back_frame = BackFrame.new(@config, group_name: @back_name,
                                      omit_head_ledge_plank: @omit_head_ledge_plank,
                                      omit_head_cap_beam: @omit_head_cap_beam,
                                      omit_back_outer_sisters_and_ties: @omit_back_outer_sisters_and_ties,
                                      omit_legs: @omit_legs,
                                      omit_head_outer_corner_legs: @omit_head_outer_corner_legs,
                                      only_part_names: @back_only_part_names)
      def front_frame = FrontFrame.new(@config, group_name: @front_name,
                                         omit_under_slat_foot_end_beam: @omit_under_slat_foot_end_beam,
                                         omit_foot_ledge_plank: @omit_foot_ledge_plank,
                                         omit_foot_cap_beam: @omit_foot_cap_beam,
                                         omit_legs: @omit_legs,
                                         omit_foot_outer_corner_legs: @omit_foot_outer_corner_legs,
                                         only_part_names: @front_only_part_names)

      # Returns { back: [Pillow, ...], front: [Pillow, ...] }.
      # Keys may be absent if there are no pillows for that group.
      # Individual methods skip small pillows when small_pillow_length <= 0.
      def pillows
        c  = @config
        sm = c.pillow_small_length.to_f
        case @pillow_mode
        when :extended           then _extended_pillows(c, sm)
        when :extended_one_small then _extended_one_small_pillows(c, sm)
        when :halfway            then _halfway_pillows(c, sm)
        when :retracted     then _retracted_pillows(c, sm)
        when :retracted_gnd then _retracted_gnd_pillows(c, sm)
        else {}
        end
      end

      private

      def c = @config

      # ── Shared pillow geometry ────────────────────────────────────────────

      # Y origin shared by big pillow and all couch stacks.
      # = 0 for default config (beam_y == beam_narrow), but keep formula for
      # configurations where they differ.
      def y_pillow = c.beam_y - c.beam_narrow

      def _big_pillow(note)
        Pillow.new(
          'EB | pillow | big',
          at:   [0, y_pillow, c.z_slat_top],
          size: [c.outer_width, c.pillow_big_length, c.pillow_thickness],
          config: c, note: note
        )
      end

      # ── Extended: big in back group + three smalls in front group ─────────

      def _extended_pillows(c, sm)
        back_pillows  = [_big_pillow('Extended bed; on slats between planks; +Y flush head plank.')]
        front_pillows = []

        if sm > 0
          y0 = y_pillow + c.pillow_big_length
          3.times do |i|
            # Pillows ordered foot→head (index 0 = SMALL_1 is most footward).
            y_world = y0 + ((c.small_pillow_count - 1 - i) * sm)
            front_pillows << Pillow.new(
              "EB | pillow | small | #{i + 1}",
              at:   [0, y_world - @foot_world_y, c.z_slat_top],
              size: [c.outer_width, sm, c.pillow_thickness],
              config: c,
              note: "Extended; small #{i + 1}/#{c.small_pillow_count}; equal thirds of extension gap."
            )
          end
        end

        { back: back_pillows, front: front_pillows }
      end

      # ── Ext1: 1 small flat on front (one segment extension) + 2 on big like retracted bottom of stack ─

      def _extended_one_small_pillows(c, sm)
        t            = c.pillow_thickness
        z_on_big     = c.z_slat_top + t
        back_pillows = [_big_pillow('Ext1; big flat on slats; two smalls stacked at head (same as retracted base).')]
        front_pillows = []

        if sm > 0
          # Same boxes as retracted small|3 and couch|head — two of three stack layers.
          back_pillows << Pillow.new(
            'EB | pillow | small | 2',
            at:   [0, y_pillow, z_on_big],
            size: [c.outer_width, t, sm],
            config: c,
            note: 'Ext1; upright on big at head (retracted small|3 geometry).'
          )
          back_pillows << Pillow.new(
            'EB | pillow | small | 3',
            at:   [0, y_pillow + t, z_on_big],
            size: [c.outer_width, t, sm],
            config: c,
            note: 'Ext1; second stack layer (retracted couch|head geometry).'
          )

          y0 = y_pillow + c.pillow_big_length
          front_pillows << Pillow.new(
            'EB | pillow | small | 1',
            at:   [0, y0 - @foot_world_y, c.z_slat_top],
            size: [c.outer_width, sm, c.pillow_thickness],
            config: c,
            note: 'Ext1; one flat extends frame (foot = retracted + one small).'
          )
        end

        { back: back_pillows, front: front_pillows }
      end

      # ── Halfway: big flat + couch head back + two smalls on front frame ───

      def _halfway_pillows(c, sm)
        t            = c.pillow_thickness
        z_on_big     = c.z_slat_top + t
        back_pillows = [_big_pillow('Half-extended; flat big on slats; Y span = pillow_big_length.')]
        front_pillows = []

        if sm > 0
          back_pillows << Pillow.new(
            'EB | pillow | couch | head',
            at:   [0, y_pillow, z_on_big],
            size: [c.outer_width, t, sm],
            config: c,
            note: 'Half-extended; vertical back cushion at y_pillow on top of big pillow.'
          )

          y0 = y_pillow + c.pillow_big_length
          front_pillows << Pillow.new(
            'EB | pillow | small | 3',
            at:   [0, y0 - @foot_world_y, c.z_slat_top],
            size: [c.outer_width, sm, c.pillow_thickness],
            config: c,
            note: 'Half-extended; small|3 flat; same Y slot as extended small|3.'
          )
          front_pillows << Pillow.new(
            'EB | pillow | small | 2',
            at:   [0, y0 + sm - @foot_world_y, c.z_slat_top],
            size: [c.outer_width, sm, c.pillow_thickness],
            config: c,
            note: 'Half-extended; small|2 flat; same Y slot as extended small|2.'
          )
        end

        { back: back_pillows, front: front_pillows }
      end

      # ── Retracted: big flat + couch stack (small|3 / head / right) ────────

      def _retracted_pillows(c, sm)
        t            = c.pillow_thickness
        z_on_big     = c.z_slat_top + t
        back_pillows = [_big_pillow('Retracted / couch seat; flat on slats; Y span = pillow_big_length.')]

        if sm > 0
          back_pillows << Pillow.new(
            'EB | pillow | small | 3',
            at:   [0, y_pillow, z_on_big],
            size: [c.outer_width, t, sm],
            config: c,
            note: 'Couch; small|3 vertical slab on big pillow; w×t×sm in X×Y×Z.'
          )
          back_pillows << Pillow.new(
            'EB | pillow | couch | head',
            at:   [0, y_pillow + t, z_on_big],
            size: [c.outer_width, t, sm],
            config: c,
            note: 'Couch; back cushion; pillow_thickness along Y; height = small_len; Y0 = y_pillow + t.'
          )
          back_pillows << Pillow.new(
            'EB | pillow | small | 1',
            at:   [0, y_pillow + (2 * t), z_on_big],
            size: [c.outer_width, t, sm],
            config: c,
            note: 'Retracted; 3rd small upright, same orientation as the other two; Y0 = y_pillow + 2t.'
          )
        end

        { back: back_pillows }
      end

      # ── Retracted + ground-stored smalls ──────────────────────────────────

      def _retracted_gnd_pillows(c, sm)
        back_pillows = [_big_pillow('Retracted; big on slats. Smalls stored on floor.')]

        if sm > 0
          # Three smalls laid flat on the floor (Z=0), centred in the corridor
          # between head legs and mid-run legs. Full outer_width in X (same footprint
          # as the other small pillows) so they sit flush with the frame sides.
          y_head        = -c.plank_thickness
          mid_y0_val    = (c.length_retracted - c.leg_x) + c.plank_thickness + c.mid_layout_y_shift
          pad           = c.slat_gap
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

          3.times do |i|
            y = y_cluster + ((c.small_pillow_count - 1 - i) * sm) - y_under_shift
            back_pillows << Pillow.new(
              "EB | pillow | small | #{i + 1}",
              at:   [0, y, 0],
              size: [c.outer_width, sm, c.pillow_thickness],
              config: c,
              note: "Retracted+stored; small #{i + 1}/#{c.small_pillow_count} on floor; flush with frame sides; Y clears posts; shifted −Y 20 mm."
            )
          end
        end

        { back: back_pillows }
      end
    end
  end
end
