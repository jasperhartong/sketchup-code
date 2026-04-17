# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # ── FrameAssembly — DSL base class ────────────────────────────────────────
    #
    # Subclasses call the geometry DSL methods (`beam`, `leg`, `slat`, `plank`,
    # `pillow`) inside `assemble` to build up a list of Part value objects.
    # The SketchUpRenderer walks that list to create actual SketchUp groups.
    #
    # All position/size arguments are SketchUp length values (inches internally,
    # use `.mm` literals).  Named keyword args (`at:`, `size:`) eliminate the
    # classic x/y/z/dx/dy/dz positional-argument soup.
    class FrameAssembly
      attr_reader :group_name, :parts, :hardware

      # +group_name+ becomes the Outliner name of the root group.
      # Subclasses may read +@frame_options+ (construction-step previews).
      def initialize(config, group_name:, **frame_options)
        @config        = config
        @group_name    = group_name
        @frame_options = frame_options
        @parts         = []
        @hardware      = []
        assemble
      end

      private

      # ── DSL primitives ───────────────────────────────────────────────────────

      def beam(name, at:, size:, note: nil)
        @parts << Beam.new(name, at: at, size: size, config: @config, note: note)
      end

      def leg(name, at:, size:, note: nil)
        @parts << Leg.new(name, at: at, size: size, config: @config, note: note)
      end

      def slat(name, at:, size:, note: nil)
        @parts << Slat.new(name, at: at, size: size, config: @config, note: note)
      end

      def plank(name, at:, size:, note: nil)
        @parts << Plank.new(name, at: at, size: size, config: @config, note: note)
      end

      def pillow(name, at:, size:, note: nil)
        @parts << Pillow.new(name, at: at, size: size, config: @config, note: note)
      end

      # Hardware: screws relative to a named part face (see `ScrewPlacement`).
      def screw(name, host_name:, face:, u:, v:, spec_id:, shaft_length_index: 0,
                pocket_tilt_from_normal_deg: 0, pocket_tilt_toward: :pos_v,
                pocket_away_from_host: false)
        @hardware << ScrewPlacement.new(
          name,
          host_name: host_name, face: face, u: u, v: v,
          spec_id: spec_id, shaft_length_index: shaft_length_index,
          pocket_tilt_from_normal_deg: pocket_tilt_from_normal_deg,
          pocket_tilt_toward: pocket_tilt_toward,
          pocket_away_from_host: pocket_away_from_host
        )
      end

      # ── Shared geometry helpers (used by both frames) ─────────────────────

      def c = @config

      # Returns [back_x_starts, front_x_starts] — X origin of each comb tooth.
      def slat_x_starts
        step  = 2 * (c.slat_dx + c.slat_gap)
        back  = (0...c.back_slat_count).map  { |k| k * step }
        front = (0...c.front_slat_count).map { |j| c.slat_dx + c.slat_gap + j * step }
        [back, front]
      end

      # [min_x, max_x] X-starts of the outermost back comb teeth.
      def outermost_comb_x_starts
        back_xs, front_xs = slat_x_starts
        merged = back_xs + front_xs
        [merged.min, merged.max]
      end

      # [inner_x_start, span_x] for tie beams between the **inner faces** of the outer sisters.
      # Sisters lie on the wide face (69 mm along X): inner −X at lo_x+beam_wide, inner +X at hi_x+slat_dx−beam_wide.
      # Span is 2×(beam_wide − slat_dx) shorter than the old narrow-on-edge sisters.
      def sister_tie_x
        lo_x, hi_x = outermost_comb_x_starts
        inner_lo   = lo_x + c.beam_wide
        inner_hi   = hi_x + c.slat_dx - c.beam_wide
        [inner_lo, inner_hi - inner_lo]
      end

      # [lo_x, span_x] for beams spanning the full front comb width.
      def front_comb_x
        _, front_xs = slat_x_starts
        lo = front_xs.min
        hi = front_xs.max
        [lo, (hi + c.slat_dx) - lo]
      end

      # Subclasses must implement this; it is called from initialize.
      def assemble
        raise NotImplementedError, "#{self.class}#assemble is not implemented"
      end
    end

    # ── BackFrame ─────────────────────────────────────────────────────────────
    #
    # The fixed (head) half of the bed.  Slats run toward +Y (foot direction).
    # Everything is in back-frame local space; BedPair applies the world offset.
    class BackFrame < FrameAssembly
      private

      def assemble
        unless @frame_options[:omit_legs]
          _head_legs
          _mid_run_legs
          _behind_leg_posts
        end
        _head_cap_and_ledge
        _back_slats
        _sister_beams
        _tie_beams
      end

      # ── private helpers ──────────────────────────────────────────────────

      # Head: outer ±X corner legs run through the cap band (lh_outer = z_slat_bottom).
      # Plan: BEAM_NARROW along +X (outer faces flush sisters at x=0 / x=outer_width), BEAM_WIDE along +Y
      # so the wide face meets the head cap depth (same as cap dy), not the narrow 44 mm strip.
      def _head_legs
        leg 'EB | leg | head | -X',
            at:   [0, y_head, 0],
            size: [head_corner_leg_dx, head_corner_leg_dy, lh_outer],
            note: 'Corner −X: min_x flush sister outer −X; narrow along +X, wide along +Y to match head cap.'

        leg 'EB | leg | head | +X',
            at:   [c.outer_width - head_corner_leg_dx, y_head, 0],
            size: [head_corner_leg_dx, head_corner_leg_dy, lh_outer],
            note: 'Corner +X: max_x flush sister outer +X; mirror of −X corner in plan.'

        # Inset strengtheners: plan leg_y×leg_x (44×69) so **min_x** (−X inset) / **max_x** (+X inset) mates
        # corner inner **max_x** / **min_x**; **max_z** meets head cap **min_z** (debug: cap bottom ~purple, inset top +Z).
        leg 'EB | leg | head | -X | inset',
            at:   [head_corner_leg_dx, y_head, 0],
            size: [c.leg_y, c.leg_x, head_inset_dz],
            note: 'Narrow 44 along +X from corner inner; 69 along +Y with corner; Z to cap underside.'

        leg 'EB | leg | head | +X | inset',
            at:   [c.outer_width - head_corner_leg_dx - c.leg_y, y_head, 0],
            size: [c.leg_y, c.leg_x, head_inset_dz],
            note: 'Mirror −X: max_x flush corner +X inner min_x; Z to cap underside.'
      end

      # Mid-run legs: **beam_wide** along X (same as outer sisters) so outer min_x/max_x (debug red) lines up
      # with sisters’ outer column; **beam_y** along Y with Y0 shifted so max_y stays flush with sister max_y.
      def _mid_run_legs
        leg 'EB | leg | mid run | -X',
            at:   [0, mid_leg_y0, 0],
            size: [c.beam_wide, c.beam_y, lh_mid],
            note: 'Outer −X = min_x red flush sister outer −X; narrow 44 along +Y; top flush sister bottom.'

        leg 'EB | leg | mid run | +X',
            at:   [c.outer_width - c.beam_wide, mid_leg_y0, 0],
            size: [c.beam_wide, c.beam_y, lh_mid],
            note: 'Outer +X = max_x red flush sister outer +X; mirror −X.'
      end

      # Four 44×69 stock posts — one behind each outer leg in head and mid Y bands
      # (same section as legs; named under EB | leg | for clarity).
      def _behind_leg_posts
        # Stack +Y of head corner legs (their plan depth is BEAM_WIDE along +Y, not leg_y).
        y_head_b = y_head + head_corner_leg_dy
        y_mid_b  = mid_leg_y0 - c.leg_x

        beam 'EB | leg | post | behind head | -X',
             at:   [0, y_head_b, 0],
             size: [c.leg_x, c.leg_y, head_inset_dz],
             note: 'Rotated 69×44 in plan vs mid posts; min_x flush head −X leg; Z to cap underside like head insets.'

        beam 'EB | leg | post | behind head | +X',
             at:   [c.outer_width - c.leg_x, y_head_b, 0],
             size: [c.leg_x, c.leg_y, head_inset_dz],
             note: 'Rotated; max_x flush head +X leg outer; Z to cap underside.'

        beam 'EB | leg | post | behind mid | -X | headward',
             at:   [0, y_mid_b, 0],
             size: [c.leg_y, c.leg_x, lh_mid],
             note: '44x69 plan (leg_y×leg_x); headward of mid leg; 69 mm along Y on outer -X face.'

        beam 'EB | leg | post | behind mid | +X | headward',
             at:   [c.outer_width - c.leg_y, y_mid_b, 0],
             size: [c.leg_y, c.leg_x, lh_mid],
             note: '44x69 plan (leg_y×leg_x); headward of mid leg; 69 mm along Y on outer +X face.'
      end

      def _head_cap_and_ledge
        # Cap between inner corner-leg faces; wide face in Y×Z (69 along +Y, 44 up); min_y = y_head
        # keeps only plank_thickness headward of y=0; top flush z_slat_bottom (ledge / slat plane).
        unless @frame_options[:omit_head_cap_beam]
          beam 'EB | beam | head | cap',
               at:   [head_cap_x0, y_head, c.z_slat_bottom - c.beam_narrow],
               size: [head_cap_dx, c.beam_wide, c.beam_narrow],
               note: 'Head cap: BEAM_WIDE along +Y, BEAM_NARROW up; between inner faces of rotated head corner legs.'
        end

        # Head ledge plank: sits on top of cap + corner legs; full bed width; 2×69 mm tall.
        unless @frame_options[:omit_head_ledge_plank]
          plank 'EB | plank | head | ledge',
                at:   [0, y_head, c.z_slat_bottom],
                size: [c.outer_width, c.plank_thickness, 2 * c.beam_wide],
                note: 'On cap and corner legs; headward face flush bed end; top 2×BEAM_WIDE above z_slat_bottom.'

          # Demo hardware: validates screw transform + hole path on the head ledge top face.
          screw 'EB | screw | demo | head ledge',
                host_name: 'EB | plank | head | ledge',
                face:      :max_z,
                u:         c.outer_width / 2,
                v:         c.plank_thickness / 2,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 0
        end

        # Full-width end beam at y=0 (headward face of slat run); sits under slat bottoms.
        beam 'EB | beam | head | end',
             at:   [0, 0, c.z_slat_bottom],
             size: [c.outer_width, c.beam_y, c.beam_z],
             note: 'Head end beam 44x69 mm (beam_y × beam_z); under cap.'

        # Two screws per back slat: from headward face (:min_y, debug bright green) inward +Y
        # toward the slats; X at slat centre; Z slightly staggered on the narrow face.
        _head_end_beam_into_slats_screws
      end

      # Screws on `EB | beam | head | end`: :min_y is the headward narrow face (u +X, v +Z in part local).
      # Vertical positions at one-third and two-thirds of beam height (69 mm stock).
      def _head_end_beam_into_slats_screws
        back_xs, = slat_x_starts
        v_lower = c.beam_z / 3.0
        v_upper = (2.0 * c.beam_z) / 3.0
        back_xs.each_with_index do |x0, i|
          u = x0 + (c.slat_dx / 2.0)
          n = i + 1
          screw "EB | screw | head end | #{n}/#{c.back_slat_count} | lower",
                host_name: 'EB | beam | head | end',
                face:      :min_y,
                u:         u,
                v:         v_lower,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 0
          screw "EB | screw | head end | #{n}/#{c.back_slat_count} | upper",
                host_name: 'EB | beam | head | end',
                face:      :min_y,
                u:         u,
                v:         v_upper,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 0
        end
      end

      def _back_slats
        back_xs, = slat_x_starts
        back_xs.each_with_index do |x0, i|
          slat "EB | slat | back | #{i + 1}/#{c.back_slat_count}",
               at:   [x0, c.beam_y, c.z_slat_bottom],
               size: [c.slat_dx, c.back_slat_run_y, c.slat_dz],
               note: 'Back (fixed) comb tooth; interlocks with front slats when assembled.'
        end
      end

      def _sister_beams
        return if @frame_options[:omit_back_outer_sisters_and_ties]

        lo_x, hi_x = outermost_comb_x_starts
        y_sister    = outer_sister_head_y0
        sister_dy   = outer_sister_run_dy
        z_sister    = lh_mid

        note = 'Sister under outermost slat; stock on **wide** face (69 mm along X, 44 mm up); outer −X face at lo_x, ' \
               'outer +X face at hi_x+slat_dx; top flush slat bottom.'

        beam 'EB | beam | sister | outer -X',
             at:   [lo_x, y_sister, z_sister],
             size: [c.beam_wide, sister_dy, c.beam_narrow],
             note: note

        beam 'EB | beam | sister | outer +X',
             at:   [hi_x + c.slat_dx - c.beam_wide, y_sister, z_sister],
             size: [c.beam_wide, sister_dy, c.beam_narrow],
             note: note
      end

      def _tie_beams
        x1_tie, span_tie = sister_tie_x
        return if span_tie <= 0

        # Footward +Y by beam_wide vs older anchor (was length_retracted − beam_wide − beam_y − …).
        y_mid_tie = c.length_retracted - c.beam_y - c.plank_thickness + c.mid_layout_y_shift

        unless @frame_options[:omit_back_outer_sisters_and_ties]
          beam 'EB | beam | mid tie | between sisters',
               at:   [x1_tie, y_mid_tie, lh_mid],
               size: [span_tie, c.beam_wide, c.beam_narrow],
               note: 'Mid run; wide face horizontal in Y (69 mm); Y shifts with mid_layout_y_shift; footward +beam_wide vs legacy mid-tie line.'
        end
      end

      # ── Z and Y constants (methods keep them readable at call sites) ────────

      # +Y origin of outer sisters (same as footward face of head cap when cap is wide-on-Y).
      def outer_sister_head_y0 = (c.beam_y - c.plank_thickness) + (c.beam_wide - c.beam_narrow)

      # Sister length along +Y: full back run + ledge margin, shortened by cap wide-face Y gain, then by
      # (beam_wide − beam_y) so the footward +Y end is flush with mid-run legs (same delta as mid_layout_y_shift).
      def outer_sister_run_dy = (c.back_slat_run_y + (2 * c.plank_thickness)) - (c.beam_wide - c.beam_narrow) + c.mid_layout_y_shift

      # Head corner legs run through the cap band to z_slat_bottom.
      def lh_outer = c.outer_corner_leg_height
      # Mid-run and inset legs stop at flat sister / tie underside.
      def lh_mid   = c.mid_run_leg_height
      # Headward face of corner legs; plank_thickness before origin so ledge is flush.
      def y_head   = -c.plank_thickness
      # Mid-run leg origin Y: footward from the retracted outer face minus one leg width, then same −Y shift as foot cap alignment.
      def mid_y0 = (c.length_retracted - c.leg_x) + c.plank_thickness + c.mid_layout_y_shift

      # Rotated mid leg (beam_wide×beam_y in plan): shift +Y so max_y still matches sister foot (was leg_x along Y).
      def mid_leg_y0 = mid_y0 + (c.beam_wide - c.beam_y)

      # Head corner leg plan (wide along +Y against head cap): narrow along +X, wide along +Y.
      def head_corner_leg_dx = c.beam_narrow
      def head_corner_leg_dy = c.beam_wide

      # Head cap spans inner faces of rotated head corner legs (foot cap still uses Config#cap_x0).
      def head_cap_x0 = head_corner_leg_dx
      def head_cap_dx = c.outer_width - (2 * head_corner_leg_dx)

      # Head insets run to head cap underside (same Z as flat cap bottom = z_slat_bottom − beam_narrow).
      def head_inset_dz = c.z_slat_bottom - c.beam_narrow
    end

    # ── FrontFrame ────────────────────────────────────────────────────────────
    #
    # The sliding (foot) half of the bed.  All parts are in front-frame local
    # space.  BedPair translates the whole group by foot_world_y along +Y.
    class FrontFrame < FrameAssembly
      private

      def assemble
        _foot_legs unless @frame_options[:omit_legs]
        _foot_cap_and_ledge
        _front_slats
        _under_slat_beams
      end

      def _foot_legs
        # Outer corner legs: same plan as head (narrow 44 along +X at outer faces, wide 69 along +Y).
        leg 'EB | leg | foot | -X',
            at:   [0, y_foot, 0],
            size: [foot_corner_leg_dx, foot_corner_leg_dy, lh_outer],
            note: 'Foot −X corner: min_x flush outer; wide along +Y; top to foot cap.'

        leg 'EB | leg | foot | +X',
            at:   [c.outer_width - foot_corner_leg_dx, y_foot, 0],
            size: [foot_corner_leg_dx, foot_corner_leg_dy, lh_outer],
            note: 'Foot +X corner: max_x flush outer; mirror −X.'

        # Inset strengtheners (match head inset plan; Z to flat foot cap underside).
        leg 'EB | leg | foot | -X | inset',
            at:   [foot_corner_leg_dx, y_foot, 0],
            size: [c.leg_y, c.leg_x, foot_inset_dz],
            note: 'Inset +X of foot −X corner inner; Z to foot cap underside.'

        leg 'EB | leg | foot | +X | inset',
            at:   [c.outer_width - foot_corner_leg_dx - c.leg_y, y_foot, 0],
            size: [c.leg_y, c.leg_x, foot_inset_dz],
            note: 'Inset −X of foot +X corner inner; mirror −X foot inset.'
      end

      def _foot_cap_and_ledge
        unless @frame_options[:omit_foot_cap_beam]
          # Wide face in X×Y (69 along Y); max_y = +plank keeps only 18 mm past y=0 toward slats (+Y).
          beam 'EB | beam | foot | cap',
               at:   [foot_cap_x0, foot_cap_y0, c.z_slat_bottom - c.beam_narrow],
               size: [foot_cap_dx, c.beam_wide, c.beam_narrow],
               note: 'Foot cap: longer X between inner faces of rotated foot corners (same logic as head cap).'
        end

        # Foot ledge plank at y=0 (footward face of slat run).
        unless @frame_options[:omit_foot_ledge_plank]
          plank 'EB | plank | foot | ledge',
                at:   [0, 0, c.z_slat_bottom],
                size: [c.outer_width, c.plank_thickness, 2 * c.beam_wide],
                note: 'On cap and corner legs; full bed width; top 2×BEAM_WIDE above z_slat_bottom.'

          screw 'EB | screw | demo | foot ledge',
                host_name: 'EB | plank | foot | ledge',
                face:      :max_z,
                u:         c.outer_width / 2,
                v:         c.plank_thickness / 2,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 0
        end

        # Full-width foot end beam; footward of all slats.
        beam 'EB | beam | foot | end',
             at:   [0, -c.beam_y, c.z_slat_bottom],
             size: [c.outer_width, c.beam_y, c.beam_z],
             note: 'Foot end beam 44x69 mm (beam_y × beam_z); under cap.'

        # Two screws per front slat (one fewer than back): from footward narrow face (:max_y,
        # opposite of head end :min_y) inward −Y toward the slats; X at slat centre; Z at thirds.
        _foot_end_beam_into_slats_screws
      end

      def _foot_end_beam_into_slats_screws
        _, front_xs = slat_x_starts
        v_lower = c.beam_z / 3.0
        v_upper = (2.0 * c.beam_z) / 3.0
        fc = c.front_slat_count
        front_xs.each_with_index do |x0, i|
          u = x0 + (c.slat_dx / 2.0)
          n = i + 1
          screw "EB | screw | foot end | #{n}/#{fc} | lower",
                host_name: 'EB | beam | foot | end',
                face:      :max_y,
                u:         u,
                v:         v_lower,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 0
          screw "EB | screw | foot end | #{n}/#{fc} | upper",
                host_name: 'EB | beam | foot | end',
                face:      :max_y,
                u:         u,
                v:         v_upper,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 0
        end
      end

      def _front_slats
        _, front_xs = slat_x_starts
        y_slat_start = -c.beam_y - c.front_slat_run_y
        front_xs.each_with_index do |x0, i|
          slat "EB | slat | front | #{i + 1}/#{c.front_slat_count}",
               at:   [x0, y_slat_start, c.z_slat_bottom],
               size: [c.slat_dx, c.front_slat_run_y, c.slat_dz],
               note: 'Front (sliding) comb tooth; sits in gaps of back slats; Y run = front_slat_run_y.'
        end
      end

      # Optional beam under the foot end of the front slats (sister inner span).
      def _under_slat_beams
        z_flat = c.z_slat_bottom - c.beam_narrow

        # Beam under the foot end of the front slats: wide stock face (beam_wide along +Y) to slat bottoms;
        # X span matches inner faces of outer sisters (same as mid tie).
        unless @frame_options[:omit_under_slat_foot_end_beam]
          x1_under, span_under = sister_tie_x
          if span_under.positive?
            y_slat_foot  = -c.beam_y - c.front_slat_run_y
            y_under_slat = y_slat_foot + c.foot_under_slat_beam_y_gap + c.foot_under_slat_beam_y_nudge_toward_foot - c.beam_wide

            beam 'EB | beam | front | under slats | foot end',
                 at:   [x1_under, y_under_slat, z_flat],
                 size: [span_under, c.beam_wide, c.beam_narrow],
                 note: 'Under front slats; max_z flush slat bottom; 69 mm along +Y against slats; X between sister inners; Y = slat min_y + gap + nudge toward foot − beam_wide (−Y).'
          end
        end
      end

      # ── Z and Y helpers ────────────────────────────────────────────────────

      # Foot corner legs run through the cap to z_slat_bottom.
      def lh_outer = c.outer_corner_leg_height
      # Foot corner/inset legs share Y span with foot cap (dy = beam_wide); max_y flush cap max_y (debug :max_y dark green).
      def y_foot = c.foot_corner_leg_y0

      # Foot cap (wide on Y): same min_y as foot legs; only plank_thickness past y=0 toward +Y at max_y.
      def foot_cap_y0 = c.foot_corner_leg_y0

      # Rotated foot corner legs (same section numbers as head corners).
      def foot_corner_leg_dx = c.beam_narrow
      def foot_corner_leg_dy = c.beam_wide

      # Foot cap spans inner faces of rotated foot corners (wider in X than Config#cap_dx / 69 mm legs).
      def foot_cap_x0 = foot_corner_leg_dx
      def foot_cap_dx = c.outer_width - (2 * foot_corner_leg_dx)

      # Foot insets meet flat foot cap underside (same Z as head insets).
      def foot_inset_dz = c.z_slat_bottom - c.beam_narrow
    end
  end
end
