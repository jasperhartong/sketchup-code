# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Declarative tables for preview `BedPair`s: seven construction-assembly steps
    # (headward row, progressive omissions + highlights) and five extension-degree pairs.
    #
    # Frame geometry still lives in `FrameAssembly`; each row maps to a +variant+ that
    # expands to the `omit_*` flags on `BedPair`.
    module BedPairCatalog
      # Maps assembly +variant+ symbols to the boolean flags `BedPair` forwards to
      # `BackFrame` / `FrontFrame`. +omit_legs+ is shared and skips every leg in the
      # frame; +omit_head_outer_corner_legs+ / +omit_foot_outer_corner_legs+ each skip
      # a single pair of outer corner legs (`EB | leg | head | ±X` / `EB | leg | foot | ±X`),
      # leaving the inset / mid-run / behind-leg posts that belong to the step 7
      # cap + sister sub-assemblies visible.
      VARIANT_OMITS = {
        construction_full: {
          omit_under_slat_foot_end_beam: false,
          omit_head_ledge_plank: false,
          omit_foot_ledge_plank: false,
          omit_head_cap_beam: false,
          omit_foot_cap_beam: false,
          omit_back_outer_sisters_and_ties: false,
          omit_legs: false,
          omit_head_outer_corner_legs: false,
          omit_foot_outer_corner_legs: false
        },
        # Step 3: ledges removed but under-slat foot-end beam kept (and highlighted blue
        # in +CONSTRUCTION_SPECS+ to signal it's the next piece to come off when the
        # assembly is flipped in step 4).
        construction_no_ledges_with_beam: {
          omit_under_slat_foot_end_beam: false,
          omit_head_ledge_plank: true,
          omit_foot_ledge_plank: true,
          omit_head_cap_beam: false,
          omit_foot_cap_beam: false,
          omit_back_outer_sisters_and_ties: false,
          omit_legs: false,
          omit_head_outer_corner_legs: false,
          omit_foot_outer_corner_legs: false
        },
        construction_no_ledges: {
          omit_under_slat_foot_end_beam: true,
          omit_head_ledge_plank: true,
          omit_foot_ledge_plank: true,
          omit_head_cap_beam: false,
          omit_foot_cap_beam: false,
          omit_back_outer_sisters_and_ties: false,
          omit_legs: false,
          omit_head_outer_corner_legs: false,
          omit_foot_outer_corner_legs: false
        },
        # Step 5: keep the sub-assembly legs (inset, mid-run, behind-leg posts) so they
        # can be seen attached to the caps / sisters. The head outer corners are retained
        # (they belong to the head cap sub-assembly); only the foot outer corners — which
        # are NOT part of any step 7 sub-assembly — are removed.
        flip_no_legs: {
          omit_under_slat_foot_end_beam: true,
          omit_head_ledge_plank: true,
          omit_foot_ledge_plank: true,
          omit_head_cap_beam: false,
          omit_foot_cap_beam: false,
          omit_back_outer_sisters_and_ties: false,
          omit_legs: false,
          omit_head_outer_corner_legs: false,
          omit_foot_outer_corner_legs: true
        },
        flip_no_caps: {
          omit_under_slat_foot_end_beam: true,
          omit_head_ledge_plank: true,
          omit_foot_ledge_plank: true,
          omit_head_cap_beam: true,
          omit_foot_cap_beam: true,
          omit_back_outer_sisters_and_ties: false,
          omit_legs: true,
          omit_head_outer_corner_legs: false,
          omit_foot_outer_corner_legs: false
        },
        # Preparation step: every omittable part is kept in so the frame-level part
        # whitelist (see +VARIANT_ONLY_PART_NAMES+) can pick the beam + leg
        # sub-assemblies that get fastened before meeting the slats (cap sub-assemblies
        # plus the outer-sister sub-assemblies with their pre-attached leg clusters).
        sub_assembly_prep: {
          omit_under_slat_foot_end_beam: false,
          omit_head_ledge_plank: false,
          omit_foot_ledge_plank: false,
          omit_head_cap_beam: false,
          omit_foot_cap_beam: false,
          omit_back_outer_sisters_and_ties: false,
          omit_legs: false,
          omit_head_outer_corner_legs: false,
          omit_foot_outer_corner_legs: false
        }
      }.freeze

      # Variants that render a hand-picked subset of the full bed instead of
      # using per-part omit flags. Values are procs taking the per-run +Config+
      # (so the whitelist can depend on config-derived part names like slats).
      # Absent variants produce the full assembly.
      VARIANT_ONLY_PART_NAMES = {
        sub_assembly_prep: ->(_config) {
          { back: Config::PREP_BACK_PART_NAMES, front: Config::PREP_FRONT_PART_NAMES }
        },
        # Forking (back + front interlaced) slats plus the two end beams that retain them
        # (head end on back, foot end on front) and their screws. No legs, sisters, ties,
        # caps, ledges, or under-slat mid beams.
        flip_no_caps: ->(config) {
          {
            back:  config.back_slat_group_names  + ['EB | beam | head | end'],
            front: config.front_slat_group_names + ['EB | beam | foot | end']
          }
        }
      }.freeze

      LEDGE_HEAD = 'EB | plank | head | ledge'
      LEDGE_FOOT = 'EB | plank | foot | ledge'

      # Seven construction steps: columns 0–1 upright at full extension Y; 2–6 upside-down
      # at decoupled foot Y, with extra +X from construction_flip_extra_offset_x.
      CONSTRUCTION_SPECS = [
        {
          back_name: Config::GROUP_STEP_EXT_BACK,
          front_name: Config::GROUP_STEP_EXT_FRONT,
          column: 0,
          foot: :extended,
          upside_down: false,
          variant: :construction_full,
          highlight: :head_and_foot_ledges
        },
        {
          back_name: Config::GROUP_STEP_DECOUP_BACK,
          front_name: Config::GROUP_STEP_DECOUP_FRONT,
          column: 1,
          foot: :extended,
          upside_down: false,
          variant: :construction_no_ledges_with_beam,
          highlight: :none
        },
        {
          back_name: Config::GROUP_STEP_NOLEDGES_BACK,
          front_name: Config::GROUP_STEP_NOLEDGES_FRONT,
          column: 2,
          foot: :extended,
          upside_down: true,
          variant: :construction_no_ledges_with_beam,
          highlight: :under_slat_foot_end
        },
        {
          back_name: Config::GROUP_STEP_FLIP_BACK,
          front_name: Config::GROUP_STEP_FLIP_FRONT,
          column: 3,
          foot: :decoupled,
          upside_down: true,
          variant: :construction_no_ledges,
          highlight: :flip_outer_corner_legs
        },
        {
          back_name: Config::GROUP_STEP_FLIP_NOLEGS_BACK,
          front_name: Config::GROUP_STEP_FLIP_NOLEGS_FRONT,
          column: 4,
          foot: :decoupled,
          upside_down: true,
          variant: :flip_no_legs,
          highlight: :flip_sub_assemblies
        },
        {
          back_name: Config::GROUP_STEP_FLIP_NOCAPS_BACK,
          front_name: Config::GROUP_STEP_FLIP_NOCAPS_FRONT,
          column: 5,
          foot: :decoupled,
          upside_down: true,
          variant: :flip_no_caps,
          highlight: :none
        },
        {
          back_name: Config::GROUP_STEP_PREP_BACK,
          front_name: Config::GROUP_STEP_PREP_FRONT,
          column: 6,
          foot: :decoupled,
          upside_down: true,
          variant: :sub_assembly_prep,
          highlight: :none
        }
      ].freeze

      EXTENSION_SPECS = [
        {
          back_name: Config::GROUP_EXT1_BACK,
          front_name: Config::GROUP_EXT1_FRONT,
          column: 0,
          foot: :one_small,
          pillow_mode: :extended_one_small,
          tally_stock: false
        },
        {
          back_name: Config::GROUP_HALF_BACK,
          front_name: Config::GROUP_HALF_FRONT,
          column: 1,
          foot: :halfway,
          pillow_mode: :halfway,
          tally_stock: false
        },
        {
          back_name: Config::GROUP_EXT_BACK,
          front_name: Config::GROUP_EXT_FRONT,
          column: 2,
          foot: :extended,
          pillow_mode: :extended,
          tally_stock: true
        },
        {
          back_name: Config::GROUP_RET_BACK,
          front_name: Config::GROUP_RET_FRONT,
          column: 3,
          foot: :retracted,
          pillow_mode: :retracted,
          tally_stock: false
        },
        {
          back_name: Config::GROUP_RETGND_BACK,
          front_name: Config::GROUP_RETGND_FRONT,
          column: 4,
          foot: :retracted,
          pillow_mode: :retracted_gnd,
          tally_stock: false
        }
      ].freeze

      module_function

      def construction_bed_pairs(config)
        step = config.outer_width + config.pair_gap_x
        flip_x = config.construction_flip_extra_offset_x
        row_y = config.construction_steps_row_y

        CONSTRUCTION_SPECS.map do |spec|
          col = spec[:column]
          ox = (col * step) + (spec[:upside_down] ? flip_x : 0)
          foot_y = spec[:foot] == :decoupled ? config.decoupled_front_foot_world_y : config.extended_front_foot_world_y
          hl = highlights(spec[:highlight])

          BedPair.from_assembly_row(
            config,
            back_name: spec[:back_name],
            front_name: spec[:front_name],
            offset_x: ox,
            pair_row_y: row_y,
            foot_world_y: foot_y,
            pillow_mode: nil,
            tally_stock: false,
            variant: spec[:variant],
            upside_down: spec[:upside_down],
            back_highlight_part_names: hl[:back],
            front_highlight_part_names: hl[:front]
          )
        end
      end

      def extension_degree_bed_pairs(config)
        step = config.outer_width + config.pair_gap_x

        EXTENSION_SPECS.map do |spec|
          foot_y = foot_world_y_for(config, spec[:foot])
          BedPair.new(
            config,
            back_name: spec[:back_name],
            front_name: spec[:front_name],
            offset_x: spec[:column] * step,
            foot_world_y: foot_y,
            pillow_mode: spec[:pillow_mode],
            tally_stock: spec[:tally_stock]
          )
        end
      end

      def omit_flags_for_variant(variant)
        f = VARIANT_OMITS[variant] || raise(ArgumentError, "Unknown assembly variant: #{variant.inspect}")
        f.dup
      end

      # Returns kwargs for `BedPair.new` (+back_only_part_names:+, +front_only_part_names:+).
      # Defaults both to +nil+ (no whitelist) for variants without a lookup entry.
      def only_part_names_for_variant(variant, config)
        resolver = VARIANT_ONLY_PART_NAMES[variant]
        spec = resolver ? resolver.call(config) : {}
        {
          back_only_part_names:  spec[:back],
          front_only_part_names: spec[:front]
        }
      end

      def highlights(key)
        case key
        when :under_slat_foot_end
          { back: [], front: ['EB | beam | front | under slats | foot end'] }
        when :head_and_foot_ledges
          { back: [LEDGE_HEAD], front: [LEDGE_FOOT] }
        when :none
          { back: [], front: [] }
        when :flip_outer_corner_legs
          {
            back:  Config::FLIP_OUTER_CORNER_BACK_HIGHLIGHTS,
            front: Config::FLIP_OUTER_CORNER_FRONT_HIGHLIGHTS
          }
        when :flip_head_foot_caps
          { back: ['EB | beam | head | cap'], front: ['EB | beam | foot | cap'] }
        when :flip_sub_assemblies
          {
            back:  Config::FLIP_SUB_ASSEMBLY_BACK_HIGHLIGHTS,
            front: Config::FLIP_SUB_ASSEMBLY_FRONT_HIGHLIGHTS
          }
        else
          raise ArgumentError, "Unknown construction highlight key: #{key.inspect}"
        end
      end

      def foot_world_y_for(config, key)
        case key
        when :extended then config.extended_front_foot_world_y
        when :decoupled then config.decoupled_front_foot_world_y
        when :one_small then config.one_small_extension_front_foot_world_y
        when :halfway then config.halfway_front_foot_world_y
        when :retracted then config.retracted_foot_world_y
        else
          raise ArgumentError, "Unknown foot preset: #{key.inspect}"
        end
      end
    end
  end
end
