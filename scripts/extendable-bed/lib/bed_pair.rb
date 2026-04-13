# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # A matched back + front frame at a specific world position, plus the pillows
    # that belong to this configuration (extended / halfway / retracted / stored).
    #
    # +pillow_mode+ controls which cushion arrangement is generated:
    #   :extended       — big flat + three small flats (bed fully open)
    #   :halfway        — big flat + couch head + two small flats on front frame
    #   :retracted      — big flat + couch stack (small|3 / head / right)
    #   :retracted_gnd  — big flat on slats, three smalls stored on the floor
    #   nil             — no pillows
    class BedPair
      attr_reader :back_name, :front_name, :offset_x, :foot_world_y,
                  :pillow_mode, :tally_stock

      def initialize(config,
                     back_name:,
                     front_name:,
                     offset_x:,
                     foot_world_y:,
                     pillow_mode: nil,
                     tally_stock: true)
        @config       = config
        @back_name    = back_name
        @front_name   = front_name
        @offset_x     = offset_x
        @foot_world_y = foot_world_y
        @pillow_mode  = pillow_mode
        @tally_stock  = tally_stock
      end

      def back_frame  = BackFrame.new(@config,  group_name: @back_name)
      def front_frame = FrontFrame.new(@config, group_name: @front_name)

      # Returns { back: [Pillow, ...], front: [Pillow, ...] }.
      # Keys may be absent if there are no pillows for that group.
      # Individual methods skip small pillows when small_pillow_length <= 0.
      def pillows
        c  = @config
        sm = c.pillow_small_length.to_f
        case @pillow_mode
        when :extended      then _extended_pillows(c, sm)
        when :halfway       then _halfway_pillows(c, sm)
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
            'EB | pillow | couch | right',
            at:   [c.outer_width - t, y_pillow + 2 * t, z_on_big],
            size: [t, c.outer_width, sm],
            config: c,
            note: 'Couch; +X arm; Y0 = y_pillow + 2t; clears both Y bands of couch | head.'
          )
        end

        { back: back_pillows }
      end

      # ── Retracted + ground-stored smalls ──────────────────────────────────

      def _retracted_gnd_pillows(c, sm)
        back_pillows = [_big_pillow('Retracted; big on slats. Smalls stored on floor.')]

        if sm > 0
          # Three smalls laid flat on the floor (Z=0), centred in the corridor
          # between head legs and mid-run legs.
          y_head        = -c.plank_thickness
          mid_y0_val    = (c.length_retracted - c.leg_x) + c.plank_thickness
          pad           = c.slat_gap
          y_corridor_lo = y_head + c.leg_y + pad
          y_corridor_hi = mid_y0_val - pad
          total_sm      = c.small_pillow_count * sm
          avail         = y_corridor_hi - y_corridor_lo
          y_cluster     = if avail >= total_sm
                            y_corridor_lo + ((avail - total_sm) / 2.0)
                          else
                            y_corridor_lo
                          end

          3.times do |i|
            y = y_cluster + ((c.small_pillow_count - 1 - i) * sm)
            back_pillows << Pillow.new(
              "EB | pillow | small | #{i + 1}",
              at:   [0, y, 0],
              size: [c.outer_width, sm, c.pillow_thickness],
              config: c,
              note: "Retracted+stored; small #{i + 1}/#{c.small_pillow_count} on floor (Z=0); Y between head and mid legs."
            )
          end
        end

        { back: back_pillows }
      end
    end
  end
end
