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
        _back_slats
        _fork_gap_helpers
        _outer_sisters
        _sister_tie
        _head_corner_leg_screws
        _head_cap_into_inset_leg_screws
        _head_cap_into_back_slat_hearts_screws
        _sister_tie_into_back_slat_hearts_screws
        _sister_into_behind_head_post_screws
        _behind_head_post_into_head_leg_screws
        _head_inset_leg_into_corner_leg_screws
        _mid_run_leg_max_y_screws
        _mid_run_leg_outer_x_screws
        _sister_into_behind_mid_post_screws
        _mid_run_leg_outboard_into_behind_mid_post_screws
        _back_sister_middle_screws
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
      end

      def _back_slats
        back_xs, = slat_x_starts
        back_xs.each_with_index do |x0, i|
          slat "EB | slat | back | #{i + 1}/#{c.back_slat_count}",
               at:   [x0, 0, c.z_slat_bottom],
               size: [c.slat_dx, c.back_slat_part_depth_y, c.slat_dz],
               note: 'Back (fixed) comb tooth; narrow-stock depth along +Y at the head (former separate end beam) merged into the slat; interlocks with front slats when assembled.'
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
             note: 'Mid run; wide face horizontal in Y (69 mm); max_y = retracted_frame_depth_y − plank_thickness (mirrors foot cap plank offset).'
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
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 1

          screw "EB | screw | head leg #{side} | front-top",
                host_name: host,
                face:      :min_y,
                u:         c.beam_narrow / 2.0,
                v:         c.outer_corner_leg_height - c.beam_narrow / 2.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Pin the head cap down onto each inset leg below it.
      # On the cap's top face, u runs along +X (span = head_cap_dx), v along +Y
      # (span = beam_wide). Screw heads sit centered in Y, offset by
      # beam_narrow/2 from the near end in X (one at each end, mirrored).
      def _head_cap_into_inset_leg_screws
        { '+X' => head_cap_dx - c.beam_narrow / 2.0, '-X' => c.beam_narrow / 2.0 }.each do |side, u|
          screw "EB | screw | head cap | #{side} end into inset leg",
                host_name: 'EB | beam | head | cap',
                face:      :max_z,
                u:         u,
                v:         c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Inner back slats (1-based indices) that get tie / cap heart screws along X
      # — slats 1 and 9 are outer comb teeth.
      SISTER_TIE_INTO_BACK_SLAT_HEART_INDICES = (2..8).freeze

      # Screw up from under the head cap into inner back slats 2..8 at each heart
      # (same indices and v as +_sister_tie_into_back_slat_hearts_screws+). Cap
      # :min_z matches the tie/support Z band; u is world-X minus +head_cap_x0+
      # because the cap spans only between inset legs.
      def _head_cap_into_back_slat_hearts_screws
        return if head_cap_dx <= 0

        back_xs, = slat_x_starts
        SISTER_TIE_INTO_BACK_SLAT_HEART_INDICES.each do |n|
          world_x = back_xs[n - 1] + c.slat_dx / 2.0
          screw "EB | screw | head cap | #{n}/#{c.back_slat_count} | heart",
                host_name: 'EB | beam | head | cap',
                face:      :min_z,
                u:         world_x - head_cap_x0,
                v:         c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Screw up from under the sister tie into each of the 7 inner back slats
      # (2..8) centered on each slat's heart. Tie :min_z face u runs along +X
      # (world-X minus x1_tie); v along +Y across beam_wide.
      def _sister_tie_into_back_slat_hearts_screws
        x1_tie, span_tie = sister_tie_x
        return if span_tie <= 0

        back_xs, = slat_x_starts
        SISTER_TIE_INTO_BACK_SLAT_HEART_INDICES.each do |n|
          world_x = back_xs[n - 1] + c.slat_dx / 2.0
          screw "EB | screw | sister tie | #{n}/#{c.back_slat_count} | heart",
                host_name: 'EB | beam | back | sister tie',
                face:      :min_z,
                u:         world_x - x1_tie,
                v:         c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Pin each behind-head post into the head corner leg behind it
      # (shaft runs −Y from the post's max_y face into the head leg).
      # Post local frame on :max_y face: u along +X (span = beam_wide = 69),
      # v along +Z (span = mid_run_leg_height). u flips between sides so the
      # screws land 22 mm inboard of the bed's outboard edge on each side:
      # on +X, local +X is outboard (u = beam_wide − beam_narrow/2);
      # on −X, local +X is inboard (u = beam_narrow/2). One screw high
      # (into the head leg body), one low (~beam_wide/3).
      def _behind_head_post_into_head_leg_screws
        { '+X' => c.beam_wide - c.beam_narrow / 2.0,
          '-X' => c.beam_narrow / 2.0 }.each do |side, u|
          host = "EB | leg | post | behind head | #{side}"
          screw "EB | screw | behind head post #{side} | upper into head leg",
                host_name: host,
                face:      :max_y,
                u:         u,
                v:         c.mid_run_leg_height - c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 1
          screw "EB | screw | behind head post #{side} | lower into head leg",
                host_name: host,
                face:      :max_y,
                u:         u,
                v:         c.beam_wide / 3.0,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 1
        end
      end

      # Pin the head inset leg sideways into the head corner leg beside it.
      # Inset leg part frame: 44 (X) × 69 (Y) × head_inset_dz (Z). The face
      # abutting the corner leg is :min_x on the +X side and :max_x on the
      # −X side (they share that plane). Screws enter from the accessible
      # opposite face — the inboard face — and the shaft runs through the
      # 44 mm inset leg into the corner leg. On that accessible face u runs
      # along +Y (span = beam_wide), v along +Z. One screw low
      # (v ≈ beam_narrow/3), one high (v ≈ mid_run_leg_height − beam_wide/2).
      def _head_inset_leg_into_corner_leg_screws
        { '+X' => [:min_x, c.beam_wide / 3.0], '-X' => [:max_x, c.beam_wide / 3.0] }.each do |side, (accessible_face, u)|
          host = "EB | leg | head | #{side} | inset"
          screw "EB | screw | head inset leg #{side} | lower into corner leg",
                host_name: host,
                face:      accessible_face,
                u:         u,
                v:         c.beam_narrow / 3.0,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 1
          screw "EB | screw | head inset leg #{side} | upper into corner leg",
                host_name: host,
                face:      accessible_face,
                u:         u,
                v:         c.mid_run_leg_height - c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 1
        end
      end

      # One screw on each mid-run leg's footward face (:max_y), centered in X,
      # at ~mid-height of the leg. Mid-run leg local frame on :max_y: u along
      # +X (span = beam_wide), v along +Z. u is symmetric about the leg's X
      # centerline so it's the same expression on both sides.
      def _mid_run_leg_max_y_screws
        %w[+X -X].each do |side|
          screw "EB | screw | mid run leg #{side} | max_y mid",
                host_name: "EB | leg | mid run | #{side}",
                face:      :max_y,
                u:         c.beam_wide / 2.0,
                v:         c.outer_corner_leg_height - c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm,
                shaft_length_index: 1
        end
      end

      # Two screws stacked vertically on each mid-run leg's :max_y face, at
      # the outboard side (u = beam_narrow/3 from the outboard edge), pinning
      # the leg into the behind-mid post behind it. The post only extends up
      # to mid_run_leg_height, so both screws must sit at v ≤ mid_run_leg_height.
      # v-pair matches +_behind_head_post_into_head_leg_screws+ exactly — low
      # at v = beam_wide/3, high at v = mid_run_leg_height − beam_wide/2 — so
      # the stacked screws line up in world-Z across the head and mid bands.
      # u flips between sides so the screws stay near the bed's outboard edge.
      def _mid_run_leg_outboard_into_behind_mid_post_screws
        { '+X' => c.beam_wide - c.beam_narrow / 3.0,
          '-X' => c.beam_narrow / 3.0 }.each do |side, u|
          { '-Z' => c.beam_wide / 3.0,
            '+Z' => c.mid_run_leg_height - c.beam_wide / 2.0 }.each do |z_side, v|
            screw "EB | screw | mid run leg #{side} | into behind-mid post | #{z_side}",
                  host_name: "EB | leg | mid run | #{side}",
                  face:      :max_y,
                  u:         u,
                  v:         v,
                  spec_id:   :eb_pocket_4mm,
                  shaft_length_index: 1
          end
        end
      end

      # One screw on each mid-run leg's outboard face, centered in Y, near
      # the top of the leg's lower band. Outboard is :min_x on the −X leg
      # and :max_x on the +X leg; u runs along +Y on both (span = beam_y),
      # so the u/v expressions stay identical across sides.
      def _mid_run_leg_outer_x_screws
        { '+X' => :max_x, '-X' => :min_x }.each do |side, outer_face|
          screw "EB | screw | mid run leg #{side} | outer upper",
                host_name: "EB | leg | mid run | #{side}",
                face:      outer_face,
                u:         c.beam_narrow / 2.0,
                v:         c.outer_corner_leg_height - c.beam_narrow / 3.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Pin each outer back sister down onto the behind-head post at its head end.
      # Sister local frame: u along +X (span = beam_wide), v along +Y; head end
      # is at v=0, so v = beam_narrow/3 sits ~one-third into the head band.
      def _sister_into_behind_head_post_screws
        %w[+X -X].each do |side|
          screw "EB | screw | back sister #{side} | into behind-head post",
                host_name: "EB | beam | back | sister | #{side}",
                face:      :max_z,
                u:         c.beam_wide / 2.0,
                v:         c.beam_narrow / 3.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Foot-end mirror of +_sister_into_behind_head_post_screws+: pin each
      # outer back sister down onto the behind-mid post near its footward end.
      # The sister's foot end sits at v = outer_sister_run_dy; offset back by
      # beam_wide/2 places the screw centered over the behind-mid post
      # footprint (post runs from mid_leg_y0 − leg_x to mid_leg_y0, and the
      # sister's max_y is flush with mid_leg_y0).
      def _sister_into_behind_mid_post_screws
        %w[+X -X].each do |side|
          screw "EB | screw | back sister #{side} | into behind-mid post",
                host_name: "EB | beam | back | sister | #{side}",
                face:      :max_z,
                u:         c.beam_wide / 2.0,
                v:         outer_sister_run_dy - c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Five screws up through each outer sister's :min_z: centered at mid-run
      # (v = outer_sister_run_dy / 2) plus two on each side along +Y. Step =
      # outer_sister_run_dy / this divisor → outer pair at v ≈ dy/10 and 9dy/10
      # (wider than /8). Sister :min_z face u along +X (span = beam_wide),
      # v along +Y (span = sister_dy).
      SISTER_UNDER_MINZ_V_STEP_DIVISOR = 5.0

      def _back_sister_middle_screws
        dy = outer_sister_run_dy
        return if dy <= 0

        v_mid = dy / 2.0
        step  = dy / SISTER_UNDER_MINZ_V_STEP_DIVISOR
        labels_vs = [
          ['under headward 2', v_mid - (2 * step)],
          ['under headward 1', v_mid - step],
          ['middle', v_mid],
          ['under footward 1', v_mid + step],
          ['under footward 2', v_mid + (2 * step)]
        ]
        %w[+X -X].each do |side|
          labels_vs.each do |label, v|
            screw "EB | screw | back sister #{side} | #{label}",
                  host_name: "EB | beam | back | sister | #{side}",
                  face:      :min_z,
                  u:         c.beam_wide / 2.0,
                  v:         v,
                  spec_id:   :eb_pocket_4mm
          end
        end
      end

      # Temporary gauges that should fit in the fork pockets during step 2.
      # Gauge width = slat width + two side gaps => 44 + 2*3 = 50 mm by default.
      # These are non-structural helper pieces (rendered red via construction-step styling).
      def _fork_gap_helpers
        back_xs, = slat_x_starts
        slots = back_xs.each_cons(2).map do |x1, x2|
          x_start = x1 + c.slat_dx
          [x_start, x2 - x_start]
        end
        return if slots.empty?

        gauge_width = c.slat_dx + (2 * c.slat_gap)
        slots = slots.select { |(_, span)| span >= gauge_width - 0.1.mm }
        return if slots.empty?

        helper_count = [c.fork_gap_helper_count, slots.length].min
        selected = slots.first(helper_count) || []
        return if selected.empty?

        # Flush against the headward face of the back slats (y = 0).
        y0 = 0
        helper_dz = c.beam_narrow
        # Step 2 is rendered upside down; placing helper top at z_slat_top makes
        # the helper flush with the ground after the flip+lift placement.
        z0 = c.z_slat_top - helper_dz
        selected.each_with_index do |(x_start, _span), idx|
          beam "EB | helper | fork gap | #{idx + 1}/#{helper_count}",
               at:   [x_start, y0, z0],
               size: [gauge_width, c.beam_wide, helper_dz],
               note: "Temporary fork-gap helper beam: #{gauge_width.to_mm.round(1)} mm length (slat + 2 gaps)."
        end
      end

      # ── Z / Y / plan helpers ─────────────────────────────────────────────

      # Headward face flush with the footward face of head corner legs (y = beam_wide - plank_thickness).
      # Run is shortened by beam_narrow so the foot end stays fixed (previous start sat beam_narrow into the leg).
      def outer_sister_head_y0 = c.beam_wide - c.plank_thickness
      def outer_sister_run_dy  =
        (c.back_slat_run_y + (2 * c.plank_thickness)) - (c.beam_wide - c.beam_narrow) + c.mid_layout_y_shift + c.beam_y - (2 * c.beam_narrow)

      def lh_outer = c.outer_corner_leg_height
      def lh_mid   = c.mid_run_leg_height
      def y_head   = -c.plank_thickness
      def mid_y0   = (c.retracted_frame_depth_y - c.leg_x) + c.plank_thickness + c.mid_layout_y_shift
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
        _front_slats
        _under_slat_extension_stop_plank
        _foot_corner_leg_into_inset_leg_screws
        _foot_inset_leg_inner_face_screws
        _foot_cap_into_front_slat_hearts_screws
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
      end

      def _front_slats
        _, front_xs = slat_x_starts
        front_xs.each_with_index do |x0, i|
          slat "EB | slat | front | #{i + 1}/#{c.front_slat_count}",
               at:   [x0, c.front_slat_y0, c.z_slat_bottom],
               size: [c.slat_dx, c.front_slat_run_y, c.slat_dz],
               note: 'Front (sliding) comb tooth; retracted headward edge on head cap, footward of head ledge; foot at y = 0.'
        end
      end

      # Two lateral screws per foot corner leg through the outer face into the
      # inset leg (v ≈ lh_outer − beam_wide/3) near ±Y in u. On +X/−X the outer
      # face is :max_x / :min_x; u/v are in each leg's part-local frame.
      def _foot_corner_leg_into_inset_leg_screws
        { '+X' => :max_x, '-X' => :min_x }.each do |side, outer_face|
          host = "EB | leg | foot | #{side}"
          screw "EB | screw | foot leg #{side} | upper -y | into inset leg",
                host_name: host,
                face:      outer_face,
                u:         c.beam_narrow / 3.0,
                v:         c.outer_corner_leg_height - c.beam_wide / 3.0,
                spec_id:   :eb_pocket_4mm
          screw "EB | screw | foot leg #{side} | upper +y | into inset leg",
                host_name: host,
                face:      outer_face,
                u:         c.beam_wide - c.beam_narrow / 2.0,
                v:         c.outer_corner_leg_height - c.beam_wide / 3.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Foot inset legs: two screws on the inner broad face (toward slats / bed
      # center) — matches circle proposal u/v; −X uses :max_x, +X mirror :min_x.
      def _foot_inset_leg_inner_face_screws
        {
          '-X' => { host: 'EB | leg | foot | -X | inset', face: :max_x },
          '+X' => { host: 'EB | leg | foot | +X | inset', face: :min_x }
        }.each do |side, info|
          host = info[:host]
          face = info[:face]
          u = c.beam_wide / 2.0
          screw "EB | screw | foot inset leg #{side} | lower inner face",
                host_name: host,
                face:      face,
                u:         u,
                v:         c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm
          screw "EB | screw | foot inset leg #{side} | upper inner face",
                host_name: host,
                face:      face,
                u:         u,
                v:         c.mid_run_leg_height - c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Screw up from under the foot cap into each front slat at its comb heart
      # (same :min_z / u / v pattern as +BackFrame#_head_cap_into_back_slat_hearts_screws+).
      def _foot_cap_into_front_slat_hearts_screws
        return if foot_cap_dx <= 0

        _, front_xs = slat_x_starts
        (1..c.front_slat_count).each do |n|
          world_x = front_xs[n - 1] + c.slat_dx / 2.0
          screw "EB | screw | foot cap | #{n}/#{c.front_slat_count} | heart",
                host_name: 'EB | beam | foot | cap',
                face:      :min_z,
                u:         world_x - foot_cap_x0,
                v:         c.beam_wide / 2.0,
                spec_id:   :eb_pocket_4mm
        end
      end

      # Plank stop under front slats (sister inner span): limits extension against back mid tie.
      def _under_slat_extension_stop_plank
        x1_under, span_under = sister_tie_x
        return unless span_under.positive?

        plank 'EB | plank | front | under slat extension stop',
              at:   [x1_under, c.front_extension_stop_y0, c.z_slat_bottom - c.plank_thickness],
              size: [span_under, c.extension_stop_plank_width, c.plank_thickness],
              note: 'Under front slats; width = mid_tie_y0 − usable_length_extended − front_extension_stop_y0; footward face meets back mid tie when extended.'
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
