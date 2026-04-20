# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Before the catalog refactor, BackFrame / FrontFrame were plain classes;
    # on a SketchUp session that already loaded the old code a `load` of this
    # file would raise "superclass mismatch". Undefine first so reloads work
    # cleanly across sessions.
    %i[FrameCatalog BackFrame FrontFrame].each do |c|
      remove_const(c) if const_defined?(c, false)
    end

    # ── BackFrame / FrontFrame — Part catalogs ────────────────────────────
    #
    # Both frames subclass SketchupUtils::PartCatalog. They are pure data:
    # given a Config they produce a fixed set of Part value objects and
    # ScrewPlacement hardware entries — built ONCE per Config, shared
    # across every preview. Per-preview selection happens at render time
    # via +PartCatalog#view(exclude: ...)+.
    #
    # All position/size arguments are SketchUp Length values (inches
    # internally; use `.mm` literals).

    # Common base: threads the config through and exposes the geometry
    # helpers used by both frame subclasses.
    class FrameCatalog < SketchupUtils::PartCatalog
      def initialize(config)
        @config = config
        super(
          section_sides:    [config.beam_narrow, config.beam_wide],
          plank_thickness:  config.plank_thickness,
          pillow_thickness: config.pillow_thickness,
          screw_specs:      config.screw_specs
        )
      end

      protected

      def c = @config

      # [back_x_starts, front_x_starts] — X origin of each comb tooth.
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

      # [inner_x_start, span_x] for tie beams between **inner faces** of the outer sisters.
      # Sisters lie on the wide face (69 mm along X): inner −X at lo_x+beam_wide, inner +X at hi_x+slat_dx−beam_wide.
      def sister_tie_x
        lo_x, hi_x = outermost_comb_x_starts
        inner_lo   = lo_x + c.beam_wide
        inner_hi   = hi_x + c.slat_dx - c.beam_wide
        [inner_lo, inner_hi - inner_lo]
      end
    end

    # ── BackFrame ─────────────────────────────────────────────────────────
    # The fixed (head) half of the bed. Slats run toward +Y (foot direction).
    # Everything is in back-frame local space; BedPair applies the world offset.
    class BackFrame < FrameCatalog
      def assemble
        _head_legs
        _mid_run_legs
        _behind_leg_posts
        _head_cap_beam
        _head_ledge_plank
        _head_end_beam
        _back_slats
        _outer_sisters
        _sister_tie
        _head_corner_leg_screws
      end

      private

      # Head corner legs (through cap band to z_slat_bottom): BEAM_NARROW along +X
      # (outer faces flush sisters at x=0 / x=outer_width), BEAM_WIDE along +Y.
      def _head_legs
        leg 'EB | leg | head | -X',
            at:   [0, y_head, 0],
            size: [head_corner_leg_dx, head_corner_leg_dy, lh_outer],
            note: 'Corner −X: min_x flush sister outer −X; narrow along +X, wide along +Y to match head cap.'

        leg 'EB | leg | head | +X',
            at:   [c.outer_width - head_corner_leg_dx, y_head, 0],
            size: [head_corner_leg_dx, head_corner_leg_dy, lh_outer],
            note: 'Corner +X: max_x flush sister outer +X; mirror of −X corner in plan.'

        leg 'EB | leg | head | -X | inset',
            at:   [head_corner_leg_dx, y_head, 0],
            size: [c.leg_y, c.leg_x, head_inset_dz],
            note: 'Narrow 44 along +X from corner inner; 69 along +Y with corner; Z to cap underside.'

        leg 'EB | leg | head | +X | inset',
            at:   [c.outer_width - head_corner_leg_dx - c.leg_y, y_head, 0],
            size: [c.leg_y, c.leg_x, head_inset_dz],
            note: 'Mirror −X: max_x flush corner +X inner min_x; Z to cap underside.'
      end

      # Mid-run legs: beam_wide along X (flush with outer sisters), beam_y along Y.
      # Extends through sister's Z band to z_slat_bottom.
      def _mid_run_legs
        leg 'EB | leg | mid run | -X',
            at:   [0, mid_leg_y0, 0],
            size: [c.beam_wide, c.beam_y, c.z_slat_bottom],
            note: 'Outer −X flush sister outer −X; narrow 44 along +Y; extends up through sister band to slat bottom.'

        leg 'EB | leg | mid run | +X',
            at:   [c.outer_width - c.beam_wide, mid_leg_y0, 0],
            size: [c.beam_wide, c.beam_y, c.z_slat_bottom],
            note: 'Outer +X flush sister outer +X; mirror −X.'
      end

      # Four 44×69 stock posts — one behind each outer leg in head and mid Y bands.
      def _behind_leg_posts
        y_head_b = y_head + head_corner_leg_dy
        y_mid_b  = mid_leg_y0 - c.leg_x

        beam 'EB | leg | post | behind head | -X',
             at:   [0, y_head_b, 0],
             size: [c.leg_x, c.leg_y, head_inset_dz],
             note: 'Rotated 69×44 in plan vs mid posts; min_x flush head −X leg; Z to cap underside.'

        beam 'EB | leg | post | behind head | +X',
             at:   [c.outer_width - c.leg_x, y_head_b, 0],
             size: [c.leg_x, c.leg_y, head_inset_dz],
             note: 'Rotated; max_x flush head +X leg outer; Z to cap underside.'

        beam 'EB | leg | post | behind mid | -X',
             at:   [0, y_mid_b, 0],
             size: [c.leg_y, c.leg_x, lh_mid],
             note: '44x69 plan (leg_y×leg_x); headward of mid leg; 69 mm along Y on outer −X face.'

        beam 'EB | leg | post | behind mid | +X',
             at:   [c.outer_width - c.leg_y, y_mid_b, 0],
             size: [c.leg_y, c.leg_x, lh_mid],
             note: '44x69 plan (leg_y×leg_x); headward of mid leg; 69 mm along Y on outer +X face.'
      end

      def _head_cap_beam
        beam 'EB | beam | head | cap',
             at:   [head_cap_x0, y_head, c.z_slat_bottom - c.beam_narrow],
             size: [head_cap_dx, c.beam_wide, c.beam_narrow],
             note: 'Head cap: BEAM_WIDE along +Y, BEAM_NARROW up; between inner faces of rotated head corner legs.'
      end

      def _head_ledge_plank
        plank 'EB | plank | head | ledge',
              at:   [0, y_head, c.z_slat_bottom],
              size: [c.outer_width, c.plank_thickness, 2 * c.beam_wide],
              note: 'On cap and corner legs; full bed width; top 2×BEAM_WIDE above z_slat_bottom.'

        screw 'EB | screw | demo | head ledge',
              host_name: 'EB | plank | head | ledge',
              face:      :max_z,
              u:         c.outer_width / 2,
              v:         c.plank_thickness / 2,
              spec_id:   :eb_pocket_4mm,
              shaft_length_index: 0
      end

      def _head_end_beam
        beam 'EB | beam | head | end',
             at:   [0, 0, c.z_slat_bottom],
             size: [c.outer_width, c.beam_y, c.beam_z],
             note: 'Head end beam 44x69 mm (beam_y × beam_z); under cap.'

        _head_end_beam_into_slats_screws
      end

      # :min_y is the headward narrow face (u +X, v +Z in part local).
      # Vertical positions at one-third and two-thirds of beam height.
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
                u:         u, v: v_lower,
                spec_id:   :eb_pocket_4mm
          screw "EB | screw | head end | #{n}/#{c.back_slat_count} | upper",
                host_name: 'EB | beam | head | end',
                face:      :min_y,
                u:         u, v: v_upper,
                spec_id:   :eb_pocket_4mm
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

      def _outer_sisters
        lo_x, hi_x = outermost_comb_x_starts
        y_sister   = outer_sister_head_y0
        sister_dy  = outer_sister_run_dy
        z_sister   = lh_mid

        note = 'Sister under outermost slat; stock on wide face (69 mm along X, 44 mm up); outer face flush slat outer; top flush slat bottom.'

        beam 'EB | beam | back | sister | -X',
             at:   [lo_x, y_sister, z_sister],
             size: [c.beam_wide, sister_dy, c.beam_narrow],
             note: note

        beam 'EB | beam | back | sister | +X',
             at:   [hi_x + c.slat_dx - c.beam_wide, y_sister, z_sister],
             size: [c.beam_wide, sister_dy, c.beam_narrow],
             note: note
      end

      def _sister_tie
        x1_tie, span_tie = sister_tie_x
        return if span_tie <= 0

        beam 'EB | beam | back | sister tie',
             at:   [x1_tie, c.mid_tie_y0, lh_mid],
             size: [span_tie, c.beam_wide, c.beam_narrow],
             note: 'Mid run; wide face horizontal in Y (69 mm); max_y = length_retracted − plank_thickness (mirrors foot cap plank offset).'
      end

      # Head corner leg screws, mirrored across the X-centerline of the bed.
      # Each leg box is 44×69×191 in its own local frame, so `u` and `v` are
      # identical on both sides; only the outer-face key flips (`:max_x` on +X
      # leg, `:min_x` on −X leg) since "outer" means a different local face in
      # each leg's frame. The headward face `:min_y` is the same on both.
      def _head_corner_leg_screws
        { '+X' => :max_x, '-X' => :min_x }.each do |side, outer_face|
          host = "EB | leg | head | #{side}"

          screw "EB | screw | head leg #{side} | outer-top",
                host_name: host,
                face:      outer_face,
                u:         c.beam_wide / 2.0,
                v:         c.outer_corner_leg_height - c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm

          screw "EB | screw | head leg #{side} | front-top",
                host_name: host,
                face:      :min_y,
                u:         c.beam_narrow / 2.0,
                v:         c.outer_corner_leg_height - c.beam_narrow / 2.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # ── Z / Y / plan helpers ─────────────────────────────────────────────

      def outer_sister_head_y0 = (c.beam_y - c.plank_thickness) + (c.beam_wide - c.beam_narrow)
      def outer_sister_run_dy  = (c.back_slat_run_y + (2 * c.plank_thickness)) - (c.beam_wide - c.beam_narrow) + c.mid_layout_y_shift - c.beam_narrow

      def lh_outer = c.outer_corner_leg_height
      def lh_mid   = c.mid_run_leg_height
      def y_head   = -c.plank_thickness
      def mid_y0   = (c.length_retracted - c.leg_x) + c.plank_thickness + c.mid_layout_y_shift
      def mid_leg_y0 = mid_y0 + (c.beam_wide - c.beam_y)

      def head_corner_leg_dx = c.beam_narrow
      def head_corner_leg_dy = c.beam_wide
      def head_cap_x0 = head_corner_leg_dx
      def head_cap_dx = c.outer_width - (2 * head_corner_leg_dx)
      def head_inset_dz = c.z_slat_bottom - c.beam_narrow
    end

    # ── FrontFrame ────────────────────────────────────────────────────────
    # The sliding (foot) half of the bed. All parts are in front-frame local
    # space; BedPair translates the whole group by foot_world_y along +Y.
    class FrontFrame < FrameCatalog
      def assemble
        _foot_legs
        _foot_cap_beam
        _foot_ledge_plank
        _foot_end_beam
        _front_slats
        _under_slat_foot_beam
      end

      private

      def _foot_legs
        leg 'EB | leg | foot | -X',
            at:   [0, y_foot, 0],
            size: [foot_corner_leg_dx, foot_corner_leg_dy, lh_outer],
            note: 'Foot −X corner: min_x flush outer; wide along +Y; top to foot cap.'

        leg 'EB | leg | foot | +X',
            at:   [c.outer_width - foot_corner_leg_dx, y_foot, 0],
            size: [foot_corner_leg_dx, foot_corner_leg_dy, lh_outer],
            note: 'Foot +X corner: max_x flush outer; mirror −X.'

        leg 'EB | leg | foot | -X | inset',
            at:   [foot_corner_leg_dx, y_foot, 0],
            size: [c.leg_y, c.leg_x, foot_inset_dz],
            note: 'Inset +X of foot −X corner inner; Z to foot cap underside.'

        leg 'EB | leg | foot | +X | inset',
            at:   [c.outer_width - foot_corner_leg_dx - c.leg_y, y_foot, 0],
            size: [c.leg_y, c.leg_x, foot_inset_dz],
            note: 'Inset −X of foot +X corner inner; mirror −X foot inset.'
      end

      def _foot_cap_beam
        beam 'EB | beam | foot | cap',
             at:   [foot_cap_x0, foot_cap_y0, c.z_slat_bottom - c.beam_narrow],
             size: [foot_cap_dx, c.beam_wide, c.beam_narrow],
             note: 'Foot cap: longer X between inner faces of rotated foot corners (same logic as head cap).'
      end

      def _foot_ledge_plank
        plank 'EB | plank | foot | ledge',
              at:   [0, 0, c.z_slat_bottom],
              size: [c.outer_width, c.plank_thickness, 2 * c.beam_wide],
              note: 'On cap and corner legs; full bed width; top 2×BEAM_WIDE above z_slat_bottom.'

        screw 'EB | screw | demo | foot ledge',
              host_name: 'EB | plank | foot | ledge',
              face:      :max_z,
              u:         c.outer_width / 2,
              v:         c.plank_thickness / 2,
              spec_id:   :eb_pocket_4mm
      end

      def _foot_end_beam
        beam 'EB | beam | foot | end',
             at:   [0, -c.beam_y, c.z_slat_bottom],
             size: [c.outer_width, c.beam_y, c.beam_z],
             note: 'Foot end beam 44x69 mm (beam_y × beam_z); under cap.'

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
                u:         u, v: v_lower,
                spec_id:   :eb_pocket_4mm
          screw "EB | screw | foot end | #{n}/#{fc} | upper",
                host_name: 'EB | beam | foot | end',
                face:      :max_y,
                u:         u, v: v_upper,
                spec_id:   :eb_pocket_4mm
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

      # Beam under the foot end of the front slats (sister inner span).
      def _under_slat_foot_beam
        x1_under, span_under = sister_tie_x
        return unless span_under.positive?

        z_flat = c.z_slat_bottom - c.beam_narrow
        beam 'EB | beam | front | under slat foot',
             at:   [x1_under, c.under_slat_foot_beam_y0, z_flat],
             size: [span_under, c.beam_wide, c.beam_narrow],
             note: 'Under front slats; max_z flush slat bottom; 69 mm along +Y against slats; X between sister inners; max_y flush with back sister tie min_y when extended.'
      end

      # ── Z / Y / plan helpers ─────────────────────────────────────────────

      def lh_outer = c.outer_corner_leg_height
      def y_foot   = c.foot_corner_leg_y0

      def foot_cap_y0 = c.foot_corner_leg_y0
      def foot_corner_leg_dx = c.beam_narrow
      def foot_corner_leg_dy = c.beam_wide
      def foot_cap_x0 = foot_corner_leg_dx
      def foot_cap_dx = c.outer_width - (2 * foot_corner_leg_dx)
      def foot_inset_dz = c.z_slat_bottom - c.beam_narrow
    end
  end
end
