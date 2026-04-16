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

      # [inner_x_start, span_x] for tie beams between the outer sisters.
      def sister_tie_x
        lo_x, hi_x = outermost_comb_x_starts
        x1          = lo_x + c.slat_dx
        [x1, hi_x - x1]
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
        _sister_outer_minus_x_tie_screws
        _sister_outer_plus_x_tie_screws
      end

      # ── private helpers ──────────────────────────────────────────────────

      # Head: outer ±X corner legs run through the cap band (lh_outer = z_slat_bottom).
      def _head_legs
        leg 'EB | leg | head | -X',
            at:   [0, y_head, 0],
            size: [c.leg_x, c.leg_y, lh_outer],
            note: 'Corner leg at head (+Y), -X; extruded to top of head cap; inner +X face bears cap end.'

        leg 'EB | leg | head | +X',
            at:   [c.outer_width - c.leg_x, y_head, 0],
            size: [c.leg_x, c.leg_y, lh_outer],
            note: 'Corner leg at head (+Y), +X; extruded to top of head cap; inner -X face bears cap end.'

        # Inset strengtheners flush on inner ±X faces of corner legs (stop at leg_height).
        leg 'EB | leg | head | -X | inset',
            at:   [c.leg_x, y_head, 0],
            size: [c.leg_x, c.leg_y, c.leg_height],
            note: 'Inset strengthener; duplicate of EB | leg | head | -X, +X of its inner face.'

        leg 'EB | leg | head | +X | inset',
            at:   [c.outer_width - 2 * c.leg_x, y_head, 0],
            size: [c.leg_x, c.leg_y, c.leg_height],
            note: 'Inset strengthener; duplicate of EB | leg | head | +X, -X of its inner face.'
      end

      # Mid-run legs: narrow (44 mm) along X at outer column, wide (69 mm) along Y.
      def _mid_run_legs
        leg 'EB | leg | mid run | -X',
            at:   [0, mid_y0, 0],
            size: [c.leg_y, c.leg_x, lh_mid],
            note: 'Mid-span leg, -X; 44 mm along X at outer column, 69 mm along Y; top flush sister bottom.'

        leg 'EB | leg | mid run | +X',
            at:   [c.outer_width - c.leg_y, mid_y0, 0],
            size: [c.leg_y, c.leg_x, lh_mid],
            note: 'Mid-span leg, +X; mirror of -X mid run leg.'
      end

      # Four 44×69 stock posts — one behind each outer leg in head and mid Y bands
      # (same section as legs; named under EB | leg | for clarity).
      def _behind_leg_posts
        y_head_b = c.leg_y - c.plank_thickness
        y_mid_b  = mid_y0 - c.leg_x

        beam 'EB | leg | post | behind head | -X',
             at:   [0, y_head_b, 0],
             size: [c.leg_y, c.leg_x, c.leg_height],
             note: '44x69 plan (leg_y×leg_x); +Y of head leg; 69 mm along Y on outer -X face.'

        beam 'EB | leg | post | behind head | +X',
             at:   [c.outer_width - c.leg_y, y_head_b, 0],
             size: [c.leg_y, c.leg_x, c.leg_height],
             note: '44x69 plan (leg_y×leg_x); +Y of head leg; 69 mm along Y on outer +X face.'

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
        # Cap between the inner faces of the corner legs; Z: leg_height..z_slat_bottom.
        unless @frame_options[:omit_head_cap_beam]
          beam 'EB | beam | head | cap',
               at:   [c.cap_x0, y_head, c.leg_height],
               size: [c.cap_dx, c.beam_y, c.beam_z],
               note: 'Head cap between outer legs: X from inner -X to inner +X; BEAM_Y × BEAM_Z in Y×Z.'
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
        y_sister    = c.beam_y - c.plank_thickness
        sister_dy   = c.back_slat_run_y + 2 * c.plank_thickness
        z_sister    = c.z_slat_bottom - c.beam_z

        note = 'Sister beam under outermost slat; -Y start offset plank_thickness to meet head legs; ' \
               '+Y length +2×plank_thickness vs back_slat_run_y; top flush slat bottom.'

        beam 'EB | beam | sister | outer -X',
             at:   [lo_x, y_sister, z_sister],
             size: [c.slat_dx, sister_dy, c.beam_z],
             note: note

        beam 'EB | beam | sister | outer +X',
             at:   [hi_x, y_sister, z_sister],
             size: [c.slat_dx, sister_dy, c.beam_z],
             note: note
      end

      def _tie_beams
        x1_tie, span_tie = sister_tie_x
        return if span_tie <= 0

        y_head_tie = c.beam_y - c.plank_thickness
        y_mid_tie  = c.length_retracted - 2 * c.beam_y - c.plank_thickness

        unless @frame_options[:omit_back_outer_sisters_and_ties]
          beam 'EB | beam | head tie | between sisters',
               at:   [x1_tie, y_head_tie, lh_mid],
               size: [span_tie, c.beam_y, c.beam_z],
               note: 'At head (+Y) end of sister run; same Z as sisters; spans X between outer sister inner faces.'

          beam 'EB | beam | mid tie | between sisters',
               at:   [x1_tie, y_mid_tie, lh_mid],
               size: [span_tie, c.beam_y, c.beam_z],
               note: 'Near mid-run legs (y = length_retracted - 2×beam_y); same Z as sisters.'
        end

        # Vertical posts beside mid-run legs (same Y band as mid tie); omitted with legs.
        unless @frame_options[:omit_legs]
          beam 'EB | leg | post | mid tie filler | -X',
               at:   [c.leg_y, y_mid_tie, 0],
               size: [c.leg_x, c.beam_y, lh_mid],
               note: 'Under mid tie; z=0..lh_mid; inner +X face flush inner -X of mid leg -X; beam_wide along +X.'

          beam 'EB | leg | post | mid tie filler | +X',
               at:   [c.outer_width - c.leg_y - c.leg_x, y_mid_tie, 0],
               size: [c.leg_x, c.beam_y, lh_mid],
               note: 'Under mid tie; z=0..lh_mid; inner -X face flush inner +X of mid leg +X; beam_wide along +X.'
        end
      end

      # From outer -X sister's :min_x (bright red) inward +X toward head/mid tie centres.
      def _sister_outer_minus_x_tie_screws
        return if @frame_options[:omit_back_outer_sisters_and_ties]

        _, span_tie = sister_tie_x
        return if span_tie <= 0

        y_sister = c.beam_y - c.plank_thickness
        y_head_tie = c.beam_y - c.plank_thickness
        y_mid_tie  = c.length_retracted - (2 * c.beam_y) - c.plank_thickness

        host = 'EB | beam | sister | outer -X'
        v_lo = c.beam_z / 3.0
        v_hi = (2.0 * c.beam_z) / 3.0

        u_head = (y_head_tie + (c.beam_y / 2.0)) - y_sister
        u_mid  = (y_mid_tie + (c.beam_y / 2.0)) - y_sister

        screw 'EB | screw | sister -X | head tie | lower',
              host_name: host,
              face:      :min_x,
              u:         u_head,
              v:         v_lo,
              spec_id:   :eb_pocket_4mm,
              shaft_length_index: 0
        screw 'EB | screw | sister -X | head tie | upper',
              host_name: host,
              face:      :min_x,
              u:         u_head,
              v:         v_hi,
              spec_id:   :eb_pocket_4mm,
              shaft_length_index: 0

        screw 'EB | screw | sister -X | mid tie | lower',
              host_name: host,
              face:      :min_x,
              u:         u_mid,
              v:         v_lo,
              spec_id:   :eb_pocket_4mm,
              shaft_length_index: 0
        screw 'EB | screw | sister -X | mid tie | upper',
              host_name: host,
              face:      :min_x,
              u:         u_mid,
              v:         v_hi,
              spec_id:   :eb_pocket_4mm,
              shaft_length_index: 0
      end

      # Mirror of _sister_outer_minus_x_tie_screws: :max_x (dark red) inward −X into the same ties.
      def _sister_outer_plus_x_tie_screws
        return if @frame_options[:omit_back_outer_sisters_and_ties]

        _, span_tie = sister_tie_x
        return if span_tie <= 0

        y_sister = c.beam_y - c.plank_thickness
        y_head_tie = c.beam_y - c.plank_thickness
        y_mid_tie  = c.length_retracted - (2 * c.beam_y) - c.plank_thickness

        host = 'EB | beam | sister | outer +X'
        v_lo = c.beam_z / 3.0
        v_hi = (2.0 * c.beam_z) / 3.0

        u_head = (y_head_tie + (c.beam_y / 2.0)) - y_sister
        u_mid  = (y_mid_tie + (c.beam_y / 2.0)) - y_sister

        screw 'EB | screw | sister +X | head tie | lower',
              host_name: host,
              face:      :max_x,
              u:         u_head,
              v:         v_lo,
              spec_id:   :eb_pocket_4mm,
              shaft_length_index: 0
        screw 'EB | screw | sister +X | head tie | upper',
              host_name: host,
              face:      :max_x,
              u:         u_head,
              v:         v_hi,
              spec_id:   :eb_pocket_4mm,
              shaft_length_index: 0

        screw 'EB | screw | sister +X | mid tie | lower',
              host_name: host,
              face:      :max_x,
              u:         u_mid,
              v:         v_lo,
              spec_id:   :eb_pocket_4mm,
              shaft_length_index: 0
        screw 'EB | screw | sister +X | mid tie | upper',
              host_name: host,
              face:      :max_x,
              u:         u_mid,
              v:         v_hi,
              spec_id:   :eb_pocket_4mm,
              shaft_length_index: 0
      end

      # ── Z and Y constants (methods keep them readable at call sites) ────────

      # Head corner legs run through the cap band to z_slat_bottom.
      def lh_outer = c.outer_corner_leg_height
      # Mid-run and inset legs stop at leg_height (= z_slat_bottom - beam_z).
      def lh_mid   = c.mid_run_leg_height
      # Headward face of corner legs; plank_thickness before origin so ledge is flush.
      def y_head   = -c.plank_thickness
      # Mid-run leg origin Y: footward from the retracted outer face minus one leg width.
      def mid_y0   = (c.length_retracted - c.leg_x) + c.plank_thickness
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
        # Outer corner legs run through the cap band (lh_outer).
        leg 'EB | leg | foot | -X',
            at:   [0, y_foot, 0],
            size: [c.leg_x, c.leg_y, lh_outer],
            note: 'Corner leg at foot (-Y), -X; extruded to top of foot cap; inner +X face bears cap end.'

        leg 'EB | leg | foot | +X',
            at:   [c.outer_width - c.leg_x, y_foot, 0],
            size: [c.leg_x, c.leg_y, lh_outer],
            note: 'Corner leg at foot (-Y), +X; extruded to top of foot cap; inner -X face bears cap end.'

        # Inset strengtheners stop at leg_height.
        leg 'EB | leg | foot | -X | inset',
            at:   [c.leg_x, y_foot, 0],
            size: [c.leg_x, c.leg_y, c.leg_height],
            note: 'Inset strengthener; duplicate of EB | leg | foot | -X, +X of its inner face.'

        leg 'EB | leg | foot | +X | inset',
            at:   [c.outer_width - 2 * c.leg_x, y_foot, 0],
            size: [c.leg_x, c.leg_y, c.leg_height],
            note: 'Inset strengthener; duplicate of EB | leg | foot | +X, -X of its inner face.'
      end

      def _foot_cap_and_ledge
        unless @frame_options[:omit_foot_cap_beam]
          beam 'EB | beam | foot | cap',
               at:   [c.cap_x0, y_foot, c.leg_height],
               size: [c.cap_dx, c.beam_y, c.beam_z],
               note: 'Foot cap between outer legs: X from inner -X to inner +X; BEAM_Y × BEAM_Z.'
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

      # Two structural beams that stiffen the front frame below the foot end.
      def _under_slat_beams
        lo_x, span_x = front_comb_x
        z_lo         = c.z_slat_bottom - c.beam_z

        # Beam under the foot end of the front slats.
        unless @frame_options[:omit_under_slat_foot_end_beam]
          y_slat_foot  = -c.beam_y - c.front_slat_run_y
          y_under_slat = y_slat_foot + c.beam_y - c.plank_thickness

          beam 'EB | beam | front | under slats | foot end',
               at:   [lo_x, y_under_slat, z_lo],
               size: [span_x, c.beam_y, c.beam_z],
               note: 'Under front slats at foot end; top flush slat bottom; -Y face beam_y headward of slat foot ends.'
        end

        # Rigidity beam below the foot cap assembly.
        unless @frame_options[:omit_front_rigidity_below_foot_cap_beam]
          y_rigidity = (-2 * c.beam_y) + c.plank_thickness

          beam 'EB | beam | front | rigidity | below foot cap',
               at:   [lo_x, y_rigidity, z_lo],
               size: [span_x, c.beam_y, c.beam_z],
               note: 'Same X as under-slats beam; below foot cap band; beam_y × beam_z.'
        end
      end

      # ── Z and Y helpers ────────────────────────────────────────────────────

      # Foot corner legs run through the cap to z_slat_bottom.
      def lh_outer = c.outer_corner_leg_height
      # Front frame protrudes footward from y=0; +Y face flush with the footward end of slats.
      def y_foot   = -c.beam_y + c.plank_thickness
    end
  end
end
