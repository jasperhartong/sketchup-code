# frozen_string_literal: true

# Declarative specification for the Extendable Interlocking-Slat Bed.
#
# Call ExtendableBedSpec.build(config) to produce a DeclarationSet.
# The returned set is compiled by DeclarationsCompiler (see bed_layout.rb).
#
# All positions and sizes are derived inline from `config` — no intermediate
# constants. Local variables are used freely for repeated sub-expressions.
#
# Coordinate convention (unchanged from original):
#   +Y  head → foot (extension direction)
#   +Z  up
#   +X  left → right when looking from head
#
# Part IDs are short, local to their component group.
# SketchUp entity names are "EB | <GroupId> | <part_id>" via the compiler.
#
# Construction step scenes use hidden_components: [...] on instances to suppress
# specific parts, with floor: true to lift upside-down placements to z=0.

module Timmerman
  module ExtendableBed
    module ExtendableBedSpec
      T = Timmerman::SketchupUtils::Transform

      module_function

      def build(config)
        c = config

        # ── Shared geometry pre-calculations ────────────────────────────────────

        # Slat X origins (comb teeth).
        step      = 2 * (c.slat_dx + c.slat_gap)
        back_xs   = (0...c.back_slat_count).map  { |k| k * step }
        front_xs  = (0...c.front_slat_count).map { |j| c.slat_dx + c.slat_gap + j * step }

        # Outermost comb tooth X origins.
        lo_x = (back_xs + front_xs).min
        hi_x = (back_xs + front_xs).max

        # Sister tie span (inner faces of outermost sisters).
        inner_lo = lo_x + c.beam_wide
        inner_hi = hi_x + c.slat_dx - c.beam_wide
        x1_tie   = inner_lo
        span_tie = inner_hi - inner_lo

        # ── BackFrame Z/Y local helpers ──────────────────────────────────────────

        lh_outer_b = c.outer_corner_leg_height   # = z_slat_bottom
        lh_mid_b   = c.mid_run_leg_height         # = z_slat_bottom - beam_narrow
        y_head     = -c.plank_thickness

        head_corner_dx = c.beam_wide
        head_corner_dy = c.beam_narrow
        head_cap_x0    = head_corner_dx
        head_cap_dx_b  = c.outer_width - (2 * head_corner_dx)
        head_inset_dz  = c.z_slat_bottom - c.beam_narrow   # = lh_mid_b

        y_head_behind = y_head + head_corner_dy
        mid_y0        = (c.retracted_frame_depth_y - c.leg_x) + c.plank_thickness + c.mid_layout_y_shift
        mid_leg_y0    = mid_y0 + (c.beam_wide - c.beam_y)
        y_mid_behind  = mid_leg_y0 - c.leg_y

        outer_sister_head_y0 = c.beam_narrow - c.plank_thickness
        outer_sister_run_dy  = (c.back_slat_run_y + (2 * c.plank_thickness)) +
                               c.mid_layout_y_shift + c.beam_y - (2 * c.beam_narrow)

        # Fork gap helper geometry (step 2).
        slots = back_xs.each_cons(2).map do |x1, x2|
          x_start = x1 + c.slat_dx
          [x_start, x2 - x_start]
        end
        gauge_width  = c.slat_dx + (2 * c.slat_gap)
        valid_slots  = slots.select { |(_, span)| span >= gauge_width - 0.1.mm }
        helper_count     = [c.fork_gap_helper_count, valid_slots.length].min
        gap_helper_slots = valid_slots.first(helper_count)

        # Sister middle screw V positions.
        sister_screw_step_divisor = 5.0
        sister_mid_v  = outer_sister_run_dy / 2.0
        sister_step_v = outer_sister_run_dy / sister_screw_step_divisor
        sister_screw_label_vs = [
          ['under_headward_2', sister_mid_v - (2 * sister_step_v)],
          ['under_headward_1', sister_mid_v - sister_step_v],
          ['middle',           sister_mid_v],
          ['under_footward_1', sister_mid_v + sister_step_v],
          ['under_footward_2', sister_mid_v + (2 * sister_step_v)]
        ]

        # Inner slat indices for cap / tie screws (1-based, 2..n-1).
        inner_back_slat_indices = (2...c.back_slat_count).map { |i| i }  # 2..8 for 9 slats

        # ── FrontFrame Z/Y local helpers ──────────────────────────────────────────

        lh_outer_f    = c.outer_corner_leg_height
        y_foot        = c.foot_corner_leg_y0
        foot_cap_x0_f = c.beam_narrow
        foot_cap_dx_f = c.outer_width - (2 * c.beam_narrow)
        foot_inset_dz = c.z_slat_bottom - c.beam_narrow

        x_under, span_under = sister_tie_x_for(c, lo_x, hi_x)

        # ── Part ID registries (used in hidden_components lists below) ───────────

        back_slat_ids          = (1..c.back_slat_count).map { |i| "back_slat_#{i}" }
        front_slat_ids         = (1..c.front_slat_count).map { |i| "front_slat_#{i}" }
        back_inner_slat_ids    = (2...c.back_slat_count).map { |i| "back_slat_#{i}" }
        front_inner_slat_ids   = (2...c.front_slat_count).map { |i| "front_slat_#{i}" }

        all_back_structural_ids = [
          'head_corner_neg_x', 'head_corner_pos_x',
          'head_inset_neg_x',  'head_inset_pos_x',
          'behind_head_neg_x', 'behind_head_pos_x',
          'behind_mid_neg_x',  'behind_mid_pos_x',
          'mid_leg_neg_x',     'mid_leg_pos_x',
          'head_cap',
          'back_sister_neg_x', 'back_sister_pos_x',
          'sister_tie'
        ] + back_slat_ids

        all_front_structural_ids = [
          'foot_corner_neg_x', 'foot_corner_pos_x',
          'foot_inset_neg_x',  'foot_inset_pos_x',
          'foot_cap', 'extension_stop'
        ] + front_slat_ids

        # Construction step hidden-component lists (subtractive from full frame).
        # Step names follow CONSTRUCTION_SPECS order (step 1 = sub_assembly_prep).

        # Step 1 (sub-assembly prep): keep cap sub-assembly + both sister clusters + tie.
        step1_back_keep = %w[
          head_cap head_corner_neg_x head_corner_pos_x
          head_inset_neg_x head_inset_pos_x
          back_sister_neg_x behind_head_neg_x behind_mid_neg_x mid_leg_neg_x
          back_sister_pos_x behind_head_pos_x behind_mid_pos_x mid_leg_pos_x
          sister_tie
        ]
        step1_back_hide  = (all_back_structural_ids - step1_back_keep).uniq
        step1_front_keep = ['foot_cap']
        step1_front_hide = (all_front_structural_ids - step1_front_keep).uniq

        # Step 1 extra screw hides (conflicting mirror screws + hearts in step 1 view).
        step1_extra_back_screw_hides = [
          'back_sister_neg_x_screw_under_headward_2',
          'back_sister_neg_x_screw_under_headward_1',
          'back_sister_neg_x_screw_middle',
          'back_sister_neg_x_screw_under_footward_1',
          'back_sister_neg_x_screw_under_footward_2',
          'back_sister_pos_x_screw_under_headward_2',
          'back_sister_pos_x_screw_under_headward_1',
          'back_sister_pos_x_screw_middle',
          'back_sister_pos_x_screw_under_footward_1',
          'back_sister_pos_x_screw_under_footward_2'
        ] +
          inner_back_slat_indices.flat_map { |n|
            ["sister_tie_screw_#{n}_of_#{c.back_slat_count}_heart",
             "head_cap_screw_#{n}_of_#{c.back_slat_count}_heart"]
          } +
          (1..c.front_slat_count).map { |n|
            "foot_cap_screw_#{n}_of_#{c.front_slat_count}_heart"
          }

        # Step 2 (flip, no caps): show only slats.
        step2_back_keep  = back_slat_ids
        step2_back_hide  = (all_back_structural_ids - step2_back_keep).uniq
        step2_front_keep = front_slat_ids
        step2_front_hide = (all_front_structural_ids - step2_front_keep).uniq

        # Step 3 (flip, no legs): no foot outer corners + insets.
        step3_front_hide = %w[foot_ledge foot_corner_neg_x foot_corner_pos_x
                               foot_inset_neg_x foot_inset_pos_x]
        step3_back_hide  = ['head_ledge extension_stop']

        # Step 4 (flip, no ledges, no extension stop).
        step4_back_hide  = ['head_ledge']
        step4_front_hide = %w[foot_ledge]

        # Step 5 (extended, flip, no ledges + extension stop).
        step5_back_hide  = ['head_ledge']
        step5_front_hide = %w[foot_ledge]

        # Steps 6–7 same hide lists as 5, just different orientation / foot position.
        step6_back_hide  = step5_back_hide
        step6_front_hide = step5_front_hide

        # Steps 7–8: nothing hidden (full construction view).

        # ── Preview row / column layout ──────────────────────────────────────────

        col = c.preview_column_step          # X offset per column
        flip_extra_x = c.construction_flip_extra_offset_x
        ext_row  = c.extension_preview_row_y     # row 0
        con_row  = c.construction_steps_row_y    # row -1

        # Foot Y offsets for front frame placement in scenes.
        foot_ret  = c.retracted_foot_world_y
        foot_ext  = c.extended_front_foot_world_y
        foot_dec  = c.decoupled_front_foot_world_y
        foot_1sm  = c.one_small_extension_front_foot_world_y

        # ── Build the DeclarationSet ─────────────────────────────────────────────

        Timmerman::SketchupUtils::Declarations::SpecBuilder.build(prefix: 'EB') do

          # ════════════════════════════════════════════════════════════════════════
          # BACK FRAME
          # ════════════════════════════════════════════════════════════════════════

          component_group(id: 'BackFrame') do

            # Head corner legs (wide along +X, narrow along +Y)
            part(id: 'head_corner_neg_x', kind: :beam,
                 at:   [0, y_head, 0],
                 size: [head_corner_dx, head_corner_dy, lh_outer_b],
                 note: 'Corner −X: min_x flush outer; wide along +X with cap, narrow along +Y to sisters.')
            part(id: 'head_corner_pos_x', kind: :beam,
                 at:   [c.outer_width - head_corner_dx, y_head, 0],
                 size: [head_corner_dx, head_corner_dy, lh_outer_b],
                 note: 'Corner +X: max_x flush outer; mirror −X in plan.')
            part(id: 'head_inset_neg_x', kind: :beam,
                 at:   [head_corner_dx, y_head, 0],
                 size: [c.leg_y, c.leg_x, head_inset_dz],
                 note: 'Narrow 44 along +X from corner inner; 69 along +Y with corner; Z to cap underside.')
            part(id: 'head_inset_pos_x', kind: :beam,
                 at:   [c.outer_width - head_corner_dx - c.leg_y, y_head, 0],
                 size: [c.leg_y, c.leg_x, head_inset_dz],
                 note: 'Mirror −X: max_x flush corner +X inner min_x; Z to cap underside.')

            # Mid-run legs
            part(id: 'mid_leg_neg_x', kind: :beam,
                 at:   [0, mid_leg_y0, 0],
                 size: [c.beam_wide, c.beam_y, c.z_slat_bottom],
                 note: 'Outer −X flush sister outer −X; narrow along +Y; extends up through sister band.')
            part(id: 'mid_leg_pos_x', kind: :beam,
                 at:   [c.outer_width - c.beam_wide, mid_leg_y0, 0],
                 size: [c.beam_wide, c.beam_y, c.z_slat_bottom],
                 note: 'Outer +X flush sister outer +X; mirror −X.')

            # Behind-head and behind-mid posts
            part(id: 'behind_head_neg_x', kind: :beam,
                 at:   [0, y_head_behind, 0],
                 size: [c.leg_x, c.leg_y, head_inset_dz],
                 note: '69×44 plan; min_x flush head −X; footward face at head leg max_y; Z to cap underside.')
            part(id: 'behind_head_pos_x', kind: :beam,
                 at:   [c.outer_width - c.leg_x, y_head_behind, 0],
                 size: [c.leg_x, c.leg_y, head_inset_dz],
                 note: 'Mirror +X; max_x flush head +X outer; Z to cap underside.')
            part(id: 'behind_mid_neg_x', kind: :beam,
                 at:   [0, y_mid_behind, 0],
                 size: [c.leg_x, c.leg_y, lh_mid_b],
                 note: '69×44 plan; min_x flush mid run −X; wide face coplanar with mid run outer −X.')
            part(id: 'behind_mid_pos_x', kind: :beam,
                 at:   [c.outer_width - c.leg_x, y_mid_behind, 0],
                 size: [c.leg_x, c.leg_y, lh_mid_b],
                 note: 'Mirror +X; max_x flush mid run +X.')

            # Head cap beam
            part(id: 'head_cap', kind: :beam,
                 at:   [head_cap_x0, y_head, c.z_slat_bottom - c.beam_narrow],
                 size: [head_cap_dx_b, c.beam_wide, c.beam_narrow],
                 note: 'Head cap: BEAM_WIDE along +Y, BEAM_NARROW up; between inner faces of corner legs.')

            # Head ledge plank
            part(id: 'head_ledge', kind: :plank,
                 at:   [0, y_head, c.z_slat_bottom],
                 size: [c.outer_width, c.plank_thickness, 2 * c.beam_wide],
                 note: 'On cap and corner legs; full bed width; top 2×BEAM_WIDE above z_slat_bottom.')

            # Back slats (comb teeth)
            back_xs.each_with_index do |x0, i|
              part(id: "back_slat_#{i + 1}", kind: :beam,
                   at:   [x0, 0, c.z_slat_bottom],
                   size: [c.slat_dx, c.back_slat_part_depth_y, c.slat_dz],
                   note: 'Back (fixed) comb tooth; interlocks with front slats when assembled.')
            end

            # Outer sisters
            part(id: 'back_sister_neg_x', kind: :beam,
                 at:   [lo_x, outer_sister_head_y0, lh_mid_b],
                 size: [c.beam_wide, outer_sister_run_dy, c.beam_narrow],
                 note: 'Sister under outermost slat −X; stock wide face (69 mm along X); top flush slat bottom.')
            part(id: 'back_sister_pos_x', kind: :beam,
                 at:   [hi_x + c.slat_dx - c.beam_wide, outer_sister_head_y0, lh_mid_b],
                 size: [c.beam_wide, outer_sister_run_dy, c.beam_narrow],
                 note: 'Sister +X mirror.')

            # Sister tie (only if span > 0)
            if span_tie > 0
              part(id: 'sister_tie', kind: :beam,
                   at:   [x1_tie, c.mid_tie_y0, lh_mid_b],
                   size: [span_tie, c.beam_wide, c.beam_narrow],
                   note: 'Mid run; wide face horizontal in Y (69 mm); bridges inner faces of sisters.')
            end

            # ── Back frame screws ──────────────────────────────────────────────

            # Head corner leg screws
            {
              'neg_x' => { host: 'head_corner_neg_x', outer_face: :min_x },
              'pos_x' => { host: 'head_corner_pos_x', outer_face: :max_x }
            }.each do |side, info|
              screw(id: "head_corner_#{side}_outer_top",
                    host_id: info[:host], face: info[:outer_face],
                    u: c.beam_narrow / 2.0,
                    v: c.outer_corner_leg_height - c.beam_wide / 2.0,
                    spec_id: :eb_pocket_4mm, shaft_length_index: 1)
              screw(id: "head_corner_#{side}_front_top",
                    host_id: info[:host], face: :min_y,
                    u: c.beam_wide / 2.0,
                    v: c.outer_corner_leg_height - c.beam_narrow / 2.0,
                    spec_id: :eb_pocket_4mm)
            end

            # Head cap into inset legs
            if head_cap_dx_b > 0
              screw(id: 'head_cap_into_inset_neg_x',
                    host_id: 'head_cap', face: :max_z,
                    u: c.beam_narrow / 2.0, v: c.beam_wide / 2.0,
                    spec_id: :eb_pocket_4mm)
              screw(id: 'head_cap_into_inset_pos_x',
                    host_id: 'head_cap', face: :max_z,
                    u: head_cap_dx_b - c.beam_narrow / 2.0, v: c.beam_wide / 2.0,
                    spec_id: :eb_pocket_4mm)

              # Head cap into inner back slat hearts
              inner_back_slat_indices.each do |n|
                world_x = back_xs[n - 1] + c.slat_dx / 2.0
                screw(id: "head_cap_screw_#{n}_of_#{c.back_slat_count}_heart",
                      host_id: 'head_cap', face: :min_z,
                      u: world_x - head_cap_x0, v: c.beam_wide / 2.0,
                      spec_id: :eb_pocket_4mm)
              end
            end

            # Sister tie into inner back slat hearts
            if span_tie > 0
              inner_back_slat_indices.each do |n|
                world_x = back_xs[n - 1] + c.slat_dx / 2.0
                screw(id: "sister_tie_screw_#{n}_of_#{c.back_slat_count}_heart",
                      host_id: 'sister_tie', face: :min_z,
                      u: world_x - x1_tie, v: c.beam_wide / 2.0,
                      spec_id: :eb_pocket_4mm)
              end
            end

            # Behind-head posts into head legs
            {
              'pos_x' => { host: 'behind_head_pos_x', u: c.beam_wide - c.beam_narrow / 2.0 },
              'neg_x' => { host: 'behind_head_neg_x', u: c.beam_narrow / 2.0 }
            }.each do |side, info|
              screw(id: "behind_head_#{side}_upper_into_head_leg",
                    host_id: info[:host], face: :max_y,
                    u: info[:u], v: c.mid_run_leg_height - c.beam_wide / 2.0,
                    spec_id: :eb_pocket_4mm, shaft_length_index: 1)
              screw(id: "behind_head_#{side}_lower_into_head_leg",
                    host_id: info[:host], face: :max_y,
                    u: info[:u], v: c.beam_wide / 3.0,
                    spec_id: :eb_pocket_4mm, shaft_length_index: 1)
            end

            # Head inset legs into corner legs
            {
              'pos_x' => { host: 'head_inset_pos_x', face: :min_x },
              'neg_x' => { host: 'head_inset_neg_x', face: :max_x }
            }.each do |side, info|
              screw(id: "head_inset_#{side}_lower_into_corner",
                    host_id: info[:host], face: info[:face],
                    u: c.beam_wide / 3.0, v: c.beam_narrow / 3.0,
                    spec_id: :eb_pocket_4mm, shaft_length_index: 1)
              screw(id: "head_inset_#{side}_upper_into_corner",
                    host_id: info[:host], face: info[:face],
                    u: c.beam_wide / 3.0, v: c.mid_run_leg_height - c.beam_wide / 2.0,
                    spec_id: :eb_pocket_4mm, shaft_length_index: 1)
            end

            # Mid-run leg max_y screws
            %w[neg_x pos_x].each do |side|
              screw(id: "mid_leg_#{side}_max_y_mid",
                    host_id: "mid_leg_#{side}", face: :max_y,
                    u: c.beam_wide / 2.0,
                    v: c.outer_corner_leg_height - c.beam_wide / 2.0,
                    spec_id: :eb_pocket_4mm, shaft_length_index: 1)
            end

            # Mid-run leg outboard into behind-mid post screws
            {
              'pos_x' => { host: 'mid_leg_pos_x', u_outer: c.beam_wide - c.beam_narrow / 3.0 },
              'neg_x' => { host: 'mid_leg_neg_x', u_outer: c.beam_narrow / 3.0 }
            }.each do |side, info|
              {
                'neg_z' => c.beam_wide / 3.0,
                'pos_z' => c.mid_run_leg_height - c.beam_wide / 2.0
              }.each do |z_side, v|
                screw(id: "mid_leg_#{side}_into_behind_mid_#{z_side}",
                      host_id: info[:host], face: :max_y,
                      u: info[:u_outer], v: v,
                      spec_id: :eb_pocket_4mm, shaft_length_index: 1)
              end
            end

            # Mid-run leg outer-X screws
            {
              'pos_x' => { host: 'mid_leg_pos_x', face: :max_x },
              'neg_x' => { host: 'mid_leg_neg_x', face: :min_x }
            }.each do |side, info|
              screw(id: "mid_leg_#{side}_outer_upper",
                    host_id: info[:host], face: info[:face],
                    u: c.beam_narrow / 2.0,
                    v: c.outer_corner_leg_height - c.beam_narrow / 3.0,
                    spec_id: :eb_pocket_4mm)
            end

            # Sister into behind-head post screws
            if outer_sister_run_dy > 0
              %w[neg_x pos_x].each do |side|
                screw(id: "back_sister_#{side}_into_behind_head_post",
                      host_id: "back_sister_#{side}", face: :max_z,
                      u: c.beam_wide / 2.0, v: c.beam_narrow / 3.0,
                      spec_id: :eb_pocket_4mm)
                screw(id: "back_sister_#{side}_into_behind_mid_post",
                      host_id: "back_sister_#{side}", face: :max_z,
                      u: c.beam_wide / 2.0,
                      v: outer_sister_run_dy - c.beam_wide / 2.0,
                      spec_id: :eb_pocket_4mm)

                # Sister middle screws
                sister_screw_label_vs.each do |label, v|
                  screw(id: "back_sister_#{side}_screw_#{label}",
                        host_id: "back_sister_#{side}", face: :min_z,
                        u: c.beam_wide / 2.0, v: v,
                        spec_id: :eb_pocket_4mm)
                end
              end
            end

          end # BackFrame

          # ════════════════════════════════════════════════════════════════════════
          # FRONT FRAME
          # ════════════════════════════════════════════════════════════════════════

          component_group(id: 'FrontFrame') do

            # Foot corner legs
            part(id: 'foot_corner_neg_x', kind: :beam,
                 at:   [0, y_foot, 0],
                 size: [c.beam_narrow, c.beam_wide, lh_outer_f],
                 note: 'Foot −X corner: min_x flush outer; wide along +Y; top to foot cap.')
            part(id: 'foot_corner_pos_x', kind: :beam,
                 at:   [c.outer_width - c.beam_narrow, y_foot, 0],
                 size: [c.beam_narrow, c.beam_wide, lh_outer_f],
                 note: 'Foot +X corner: max_x flush outer; mirror −X.')
            part(id: 'foot_inset_neg_x', kind: :beam,
                 at:   [c.beam_narrow, y_foot, 0],
                 size: [c.leg_y, c.leg_x, foot_inset_dz],
                 note: 'Inset +X of foot −X corner inner; Z to foot cap underside.')
            part(id: 'foot_inset_pos_x', kind: :beam,
                 at:   [c.outer_width - c.beam_narrow - c.leg_y, y_foot, 0],
                 size: [c.leg_y, c.leg_x, foot_inset_dz],
                 note: 'Inset −X of foot +X corner inner; mirror −X foot inset.')

            # Foot cap beam
            part(id: 'foot_cap', kind: :beam,
                 at:   [foot_cap_x0_f, y_foot, c.z_slat_bottom - c.beam_narrow],
                 size: [foot_cap_dx_f, c.beam_wide, c.beam_narrow],
                 note: 'Foot cap: longer X between inner faces of rotated foot corners.')

            # Foot ledge plank
            part(id: 'foot_ledge', kind: :plank,
                 at:   [0, 0, c.z_slat_bottom],
                 size: [c.outer_width, c.plank_thickness, 2 * c.beam_wide],
                 note: 'On cap and corner legs; full bed width; top 2×BEAM_WIDE above z_slat_bottom.')

            # Front slats (comb teeth)
            front_xs.each_with_index do |x0, i|
              part(id: "front_slat_#{i + 1}", kind: :beam,
                   at:   [x0, c.front_slat_y0, c.z_slat_bottom],
                   size: [c.slat_dx, c.front_slat_run_y, c.slat_dz],
                   note: 'Front (sliding) comb tooth; foot at local y=0.')
            end

            # Extension stop plank (under front slats)
            if span_under > 0
              part(id: 'extension_stop', kind: :plank,
                   at:   [x_under, c.front_extension_stop_y0, c.z_slat_bottom - c.plank_thickness],
                   size: [span_under, c.extension_stop_plank_width, c.plank_thickness],
                   note: 'Under front slats; footward face meets back mid tie when extended.')
            end

            # ── Front frame screws ─────────────────────────────────────────────

            # Foot corner leg into inset leg screws
            {
              'neg_x' => { host: 'foot_corner_neg_x', face: :min_x },
              'pos_x' => { host: 'foot_corner_pos_x', face: :max_x }
            }.each do |side, info|
              screw(id: "foot_corner_#{side}_upper_neg_y_into_inset",
                    host_id: info[:host], face: info[:face],
                    u: c.beam_narrow / 3.0,
                    v: c.outer_corner_leg_height - c.beam_wide / 3.0,
                    spec_id: :eb_pocket_4mm)
              screw(id: "foot_corner_#{side}_upper_pos_y_into_inset",
                    host_id: info[:host], face: info[:face],
                    u: c.beam_wide - c.beam_narrow / 2.0,
                    v: c.outer_corner_leg_height - c.beam_wide / 3.0,
                    spec_id: :eb_pocket_4mm)
            end

            # Foot inset leg inner face screws
            {
              'neg_x' => { host: 'foot_inset_neg_x', face: :max_x },
              'pos_x' => { host: 'foot_inset_pos_x', face: :min_x }
            }.each do |side, info|
              screw(id: "foot_inset_#{side}_lower_inner",
                    host_id: info[:host], face: info[:face],
                    u: c.beam_wide / 2.0, v: c.beam_wide / 2.0,
                    spec_id: :eb_pocket_4mm)
              screw(id: "foot_inset_#{side}_upper_inner",
                    host_id: info[:host], face: info[:face],
                    u: c.beam_wide / 2.0,
                    v: c.mid_run_leg_height - c.beam_wide / 2.0,
                    spec_id: :eb_pocket_4mm)
            end

            # Foot cap into front slat hearts
            if foot_cap_dx_f > 0
              (1..c.front_slat_count).each do |n|
                world_x = front_xs[n - 1] + c.slat_dx / 2.0
                screw(id: "foot_cap_screw_#{n}_of_#{c.front_slat_count}_heart",
                      host_id: 'foot_cap', face: :min_z,
                      u: world_x - foot_cap_x0_f, v: c.beam_wide / 2.0,
                      spec_id: :eb_pocket_4mm)
              end
            end

            # Extension stop into front slat hearts
            if span_under > 0
              front_inner_slat_ids.each_with_index do |_, idx|
                n = idx + 2   # 1-based inner index (2..front_slat_count-1)
                world_x = front_xs[n - 1] + c.slat_dx / 2.0
                screw(id: "extension_stop_screw_#{n}_of_#{c.front_slat_count}_heart",
                      host_id: 'extension_stop', face: :min_z,
                      u: world_x - x_under,
                      v: c.extension_stop_plank_width / 2.0,
                      spec_id: :eb_pocket_4mm)
              end
            end

          end # FrontFrame

          # ════════════════════════════════════════════════════════════════════════
          # FORK GAP HELPERS (construction gauges — Declarations only)
          # ════════════════════════════════════════════════════════════════════════

          gap_helper_slots.each_with_index do |(x_start, _), idx|
            helper_dz = c.beam_narrow
            z0        = c.z_slat_top - helper_dz
            component_group(id: "ForkGapHelper#{idx + 1}") do
              part(id: 'gauge', kind: :beam,
                   at:   [x_start, 0, z0],
                   size: [gauge_width, c.beam_wide, helper_dz],
                   note: "Fork-gap gauge #{idx + 1}: #{gauge_width.to_mm.round(1)} mm (slat + 2 gaps).")
            end
          end

          # ════════════════════════════════════════════════════════════════════════
          # PILLOWS
          # ════════════════════════════════════════════════════════════════════════

          # Pillow Y origin shared for default config (beam_y == beam_narrow → 0).
          pillow_y = c.beam_y - c.beam_narrow

          component_group(id: 'PillowBig') do
            part(id: 'foam', kind: :pillow,
                 at:       [0, pillow_y, c.z_slat_top],
                 size:     [c.outer_width, c.pillow_big_length, c.pillow_thickness],
                 material: [255, 255, 255],
                 note:     'Big flat pillow; on slats between planks.')
          end

          c.small_pillow_count.times do |k|
            n = k + 1  # 1-based
            component_group(id: "PillowSmall#{n}") do
              part(id: 'foam', kind: :pillow,
                   at:       [0, 0, 0],
                   size:     [c.outer_width, c.pillow_small_length, c.pillow_thickness],
                   material: [255, 255, 255],
                   note:     "Small pillow #{n}/#{c.small_pillow_count}.")
            end
          end

          # ════════════════════════════════════════════════════════════════════════
          # COMPOSITE VARIANTS
          # ════════════════════════════════════════════════════════════════════════

          # ── Extension-degree previews ─────────────────────────────────────────

          sm = c.pillow_small_length
          y_small_head_world = pillow_y + c.pillow_big_length

          component_group(id: 'BedRetracted') do
            instance(from_id: 'BackFrame',  at: [0, 0, 0])
            instance(from_id: 'FrontFrame', at: [0, foot_ret, 0])
            # Big pillow on slats
            instance(from_id: 'PillowBig', at: [0, pillow_y, 0])
            # Small 3 flat under slats at head
            y_s3_under = -c.plank_thickness + c.beam_narrow + c.leg_y
            instance(from_id: 'PillowSmall3',
                     at: [0, y_s3_under, 0])
            # Small 1 upright at head: rotation_x_90 turns Y-length into Z-height;
            # y-offset +t corrects for the -t shift that rotation introduces.
            t = c.pillow_thickness
            z_up = c.z_slat_top + t
            t_small1 = T.translation([0, pillow_y + t, z_up]) * T.rotation_x_90
            instance(from_id: 'PillowSmall1', transform: t_small1)
            # Small 2 along +X outer edge: rotation_z_90 * rotation_x_90 produces
            # size [t, outer_width, sm] from the flat component [outer_width, sm, t].
            t_small2 = T.translation([c.outer_width - t, pillow_y + t, z_up]) *
                       T.rotation_z_90 * T.rotation_x_90
            instance(from_id: 'PillowSmall2', transform: t_small2)
          end

          component_group(id: 'BedRetractedGnd') do
            instance(from_id: 'BackFrame',  at: [0, 0, 0])
            instance(from_id: 'FrontFrame', at: [0, foot_ret, 0])
            instance(from_id: 'PillowBig', at: [0, pillow_y, 0])
            y_cluster = -c.plank_thickness + c.beam_narrow + c.leg_y
            # Smalls stored flat on floor (foot→head: 3, 1, 2)
            [3, 1, 2].each_with_index do |n, idx|
              instance(from_id: "PillowSmall#{n}",
                       at: [0, y_cluster + (idx * sm), 0])
            end
          end

          component_group(id: 'BedExtended1Small') do
            instance(from_id: 'BackFrame',  at: [0, 0, 0])
            instance(from_id: 'FrontFrame', at: [0, foot_1sm, 0])
            instance(from_id: 'PillowBig', at: [0, pillow_y, 0])
            # Small 2 + 3 upright stacked on big at head (same rotation as retracted couch).
            t = c.pillow_thickness
            z_up = c.z_slat_top + t
            t2 = T.translation([0, pillow_y + t,       z_up]) * T.rotation_x_90
            t3 = T.translation([0, pillow_y + (2 * t), z_up]) * T.rotation_x_90
            instance(from_id: 'PillowSmall2', transform: t2)
            instance(from_id: 'PillowSmall3', transform: t3)
            # Small 1 flat on front frame
            y_s1_front_local = y_small_head_world - foot_1sm
            instance(from_id: 'PillowSmall1',
                     transform: T.translation([0, y_s1_front_local + foot_1sm, c.z_slat_top]))
          end

          component_group(id: 'BedExtended') do
            instance(from_id: 'BackFrame',  at: [0, 0, 0])
            instance(from_id: 'FrontFrame', at: [0, foot_ext, 0])
            instance(from_id: 'PillowBig', at: [0, pillow_y, 0])
            # Three smalls flat in extension gap (foot→head: 3, 1, 2)
            [3, 1, 2].each_with_index do |n, idx|
              y_world = y_small_head_world + (idx * sm)
              instance(from_id: "PillowSmall#{n}",
                       at: [0, y_world, c.z_slat_top])
            end
          end

          # ════════════════════════════════════════════════════════════════════════
          # SCENES
          # ════════════════════════════════════════════════════════════════════════

          # ── Extension-degree variants row ─────────────────────────────────────

          scene(id: 'Variants') do
            instance(from_id: 'BedRetracted',     at: [0,           ext_row, 0])
            instance(from_id: 'BedExtended1Small', at: [col,        ext_row, 0])
            instance(from_id: 'BedExtended',       at: [col * 2,    ext_row, 0])
            instance(from_id: 'BedRetractedGnd',   at: [col * 3,    ext_row, 0])
          end

          # ── Construction steps — all steps in one scene ───────────────────────
          # Steps spread along X at intervals of col; upside-down steps use
          # floor: true so the flipped geometry sits on the ground plane.

          scene(id: 'ConstructionSteps') do
            # Step 1 — sub-assembly prep (upside down, decoupled).
            step1_t       = T.translation([0 + flip_extra_x, con_row, 0]) * T.rotation_y_180
            step1_t_front = T.translation([0 + flip_extra_x, con_row + foot_dec, 0]) * T.rotation_y_180
            instance(from_id: 'BackFrame',
                     transform: step1_t, floor: true,
                     hidden_components: step1_back_hide + step1_extra_back_screw_hides)
            instance(from_id: 'FrontFrame',
                     transform: step1_t_front, floor: true,
                     hidden_components: step1_front_hide)

            # Step 2 — flip, no caps (slats + gap helpers only).
            step2_t       = T.translation([col + flip_extra_x, con_row, 0]) * T.rotation_y_180
            step2_t_front = T.translation([col + flip_extra_x, con_row + foot_dec, 0]) * T.rotation_y_180
            instance(from_id: 'BackFrame',
                     transform: step2_t, floor: true,
                     hidden_components: step2_back_hide)
            instance(from_id: 'FrontFrame',
                     transform: step2_t_front, floor: true,
                     hidden_components: step2_front_hide)

            # Step 3 — flip, no outer legs.
            step3_t       = T.translation([col * 2 + flip_extra_x, con_row, 0]) * T.rotation_y_180
            step3_t_front = T.translation([col * 2 + flip_extra_x, con_row + foot_dec, 0]) * T.rotation_y_180
            instance(from_id: 'BackFrame',
                     transform: step3_t, floor: true,
                     hidden_components: step3_back_hide)
            instance(from_id: 'FrontFrame',
                     transform: step3_t_front, floor: true,
                     hidden_components: step3_front_hide)

            # Step 4 — flip, no ledges.
            step4_t       = T.translation([col * 3 + flip_extra_x, con_row, 0]) * T.rotation_y_180
            step4_t_front = T.translation([col * 3 + flip_extra_x, con_row + foot_dec, 0]) * T.rotation_y_180
            instance(from_id: 'BackFrame',
                     transform: step4_t, floor: true,
                     hidden_components: step4_back_hide)
            instance(from_id: 'FrontFrame',
                     transform: step4_t_front, floor: true,
                     hidden_components: step4_front_hide)

            # Step 5 — extended, flip, no ledges + extension stop.
            step5_t       = T.translation([col * 4 + flip_extra_x, con_row, 0]) * T.rotation_y_180
            step5_t_front = T.translation([col * 4 + flip_extra_x, con_row + foot_ext, 0]) * T.rotation_y_180
            instance(from_id: 'BackFrame',
                     transform: step5_t, floor: true,
                     hidden_components: step5_back_hide)
            instance(from_id: 'FrontFrame',
                     transform: step5_t_front, floor: true,
                     hidden_components: step5_front_hide)

            # Step 6 — extended, upright, no ledges.
            instance(from_id: 'BackFrame',
                     at: [col * 5, con_row, 0],
                     hidden_components: step6_back_hide)
            instance(from_id: 'FrontFrame',
                     at: [col * 5, con_row + foot_ext, 0],
                     hidden_components: step6_front_hide)

            # Step 7 — extended, upright, full.
            instance(from_id: 'BackFrame',  at: [col * 6, con_row, 0])
            instance(from_id: 'FrontFrame', at: [col * 6, con_row + foot_ext, 0])

            # Step 8 — retracted, upright, full.
            instance(from_id: 'BackFrame',  at: [col * 7, con_row, 0])
            instance(from_id: 'FrontFrame', at: [col * 7, con_row + foot_ret, 0])
          end

        end # SpecBuilder.build
      end

      # Compute (x1_under, span_under) for the extension stop — same formula as
      # FrameCatalog#sister_tie_x but pure-function (no state).
      def self.sister_tie_x_for(c, lo_x, hi_x)
        inner_lo = lo_x + c.beam_wide
        inner_hi = hi_x + c.slat_dx - c.beam_wide
        [inner_lo, inner_hi - inner_lo]
      end

    end
  end
end
