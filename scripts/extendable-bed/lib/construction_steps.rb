# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Declarative tables for preview BedPair instances:
    #   — 7 construction-assembly steps (headward row, progressive omissions + highlights)
    #   — extension-degree previews (the usage row)
    #
    # Each step maps to a +variant+ symbol in +VARIANT_EXCLUDES+, which lists
    # the part names to HIDE on the back and front frames (single mechanism —
    # no separate boolean omit flags, no parallel whitelist table).
    #
    # To convert a "whitelist" semantic (keep only N parts) into excludes, we
    # compute +catalog.names − whitelist+ at BedPair construction time.
    module BedPairCatalog
      G = BedPartGroups

      # ── Variant → exclude lists (back / front) ────────────────────────────
      #
      # Each value is a lambda taking (back_frame_catalog, front_frame_catalog,
      # config) and returning { back: [...], front: [...] }. Lambdas let
      # whitelists compose against the full catalog name set at render time.
      VARIANT_EXCLUDES = {
        # Step 1: full bed, nothing hidden.
        construction_full: ->(_b, _f, _c) { { back: [], front: [] } },

        # Step 3: ledges removed, under-slat-foot beam retained (then highlighted).
        construction_no_ledges_with_beam: ->(_b, _f, _c) {
          { back:  G::BACK_HEAD_LEDGE,
            front: G::FRONT_FOOT_LEDGE }
        },

        # Ledges + under-slat foot beam all gone.
        construction_no_ledges: ->(_b, _f, _c) {
          { back:  G::BACK_HEAD_LEDGE,
            front: G::FRONT_FOOT_LEDGE + G::FRONT_UNDER_SLAT_FOOT_BEAM }
        },

        # Step 5: also remove foot outer corners (they aren't part of any
        # step-7 sub-assembly, unlike the head outer corners).
        flip_no_legs: ->(_b, _f, _c) {
          { back:  G::BACK_HEAD_LEDGE,
            front: G::FRONT_FOOT_LEDGE + G::FRONT_UNDER_SLAT_FOOT_BEAM +
                   G::FRONT_FOOT_OUTER_CORNERS }
        },

        # Step 6: keep only slats + end beams (forking preview). Exclude = full − whitelist.
        flip_no_caps: ->(b, f, c) {
          back_keep  = G.fork_back_whitelist(c)
          front_keep = G.fork_front_whitelist(c)
          { back:  b.names - back_keep,
            front: f.names - front_keep }
        },

        # Step 7: cap sub-assemblies + both sister sub-assemblies joined by the mid tie.
        sub_assembly_prep: ->(b, f, _c) {
          { back:  b.names - G::PREP_BACK_WHITELIST,
            front: f.names - G::PREP_FRONT_WHITELIST }
        }
      }.freeze

      VARIANT_HIDDEN = {
        # Step 7 cleanup: hide selected mirrored screw pairs to keep the
        # sub-assembly prep view uncluttered.
        step_prep_hide_conflicting_screws: ->(_b, _f, c) {
          {
            back: [
              'EB | screw | back sister -X | middle',
              'EB | screw | back sister +X | middle',
              'EB | screw | head cap | mid 7-8 | into head end',
              'EB | screw | head cap | mid 2-3 | into head end',
              'EB | screw | head cap | mid 5-6 | into head end',
              'EB | screw | head cap | mid 4-5 | into head end',
              "EB | screw | sister tie | 8/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 2/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 7/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 3/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 6/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 4/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 5/#{c.back_slat_count} | heart"
            ],
            front: [
              'EB | screw | foot cap | mid 6-7 | into foot end',
              'EB | screw | foot cap | mid 2-3 | into foot end',
              'EB | screw | foot cap | mid 5-6 | into foot end',
              'EB | screw | foot cap | mid 3-4 | into foot end'
            ]
          }
        },

        # Keep all hosts for screw placement, then hide all part groups so only
        # screw hardware remains visible.
        screws_only: ->(b, f, _c) {
          { back: b.names, front: f.names }
        }
      }.freeze

      LEDGE_HEAD = 'EB | plank | head | ledge'
      LEDGE_FOOT = 'EB | plank | foot | ledge'

      CONSTRUCTION_SPECS = [
        { back_name: Config::GROUP_STEP_EXT_BACK,        front_name: Config::GROUP_STEP_EXT_FRONT,        column: 0, foot: :extended,  upside_down: false, variant: :construction_full,              highlight: :head_and_foot_ledges },
        { back_name: Config::GROUP_STEP_DECOUP_BACK,     front_name: Config::GROUP_STEP_DECOUP_FRONT,     column: 1, foot: :extended,  upside_down: false, variant: :construction_no_ledges_with_beam, highlight: :none },
        { back_name: Config::GROUP_STEP_NOLEDGES_BACK,   front_name: Config::GROUP_STEP_NOLEDGES_FRONT,   column: 2, foot: :extended,  upside_down: true,  variant: :construction_no_ledges_with_beam, highlight: :under_slat_foot_end },
        { back_name: Config::GROUP_STEP_FLIP_BACK,       front_name: Config::GROUP_STEP_FLIP_FRONT,       column: 3, foot: :decoupled, upside_down: true,  variant: :construction_no_ledges,         highlight: :flip_outer_corner_legs },
        { back_name: Config::GROUP_STEP_FLIP_NOLEGS_BACK, front_name: Config::GROUP_STEP_FLIP_NOLEGS_FRONT, column: 4, foot: :decoupled, upside_down: true,  variant: :flip_no_legs,                    highlight: :flip_sub_assemblies },
        { back_name: Config::GROUP_STEP_FLIP_NOCAPS_BACK, front_name: Config::GROUP_STEP_FLIP_NOCAPS_FRONT, column: 5, foot: :decoupled, upside_down: true,  variant: :flip_no_caps,                    highlight: :none },
        { back_name: Config::GROUP_STEP_PREP_BACK,        front_name: Config::GROUP_STEP_PREP_FRONT,        column: 6, foot: :decoupled, upside_down: true,  variant: :sub_assembly_prep,               highlight: :none, hidden_variant: :step_prep_hide_conflicting_screws }
      ].freeze

      EXTENSION_SPECS = [
        { back_name: Config::GROUP_EXT1_BACK,    front_name: Config::GROUP_EXT1_FRONT,    column: 0, foot: :one_small, pillow_mode: :extended_one_small, tally_stock: false },
        { back_name: Config::GROUP_HALF_BACK,    front_name: Config::GROUP_HALF_FRONT,    column: 1, foot: :halfway,   pillow_mode: :halfway,           tally_stock: false },
        { back_name: Config::GROUP_EXT_BACK,     front_name: Config::GROUP_EXT_FRONT,     column: 2, foot: :extended,  pillow_mode: :extended,          tally_stock: true  },
        { back_name: Config::GROUP_RET_BACK,     front_name: Config::GROUP_RET_FRONT,     column: 3, foot: :retracted, pillow_mode: :retracted,         tally_stock: false },
        { back_name: Config::GROUP_RETGND_BACK,  front_name: Config::GROUP_RETGND_FRONT,  column: 4, foot: :retracted, pillow_mode: :retracted_gnd,     tally_stock: false },
        { back_name: Config::GROUP_RETSCREWS_BACK, front_name: Config::GROUP_RETSCREWS_FRONT,
          column: 5, foot: :retracted, pillow_mode: nil, tally_stock: false, variant: :screws_only }
      ].freeze

      module_function

      def construction_bed_pairs(config, back_frame:, front_frame:)
        step   = config.outer_width + config.pair_gap_x
        flip_x = config.construction_flip_extra_offset_x
        row_y  = config.construction_steps_row_y

        CONSTRUCTION_SPECS.map do |spec|
          col     = spec[:column]
          ox      = (col * step) + (spec[:upside_down] ? flip_x : 0)
          foot_y  = spec[:foot] == :decoupled ? config.decoupled_front_foot_world_y : config.extended_front_foot_world_y
          hl      = highlights(spec[:highlight])
          excludes = resolve_excludes(spec[:variant], back_frame, front_frame, config)
          hidden = resolve_hidden(spec[:hidden_variant], back_frame, front_frame, config)

          BedPair.new(
            config,
            back_frame:   back_frame,
            front_frame:  front_frame,
            back_name:    spec[:back_name],
            front_name:   spec[:front_name],
            offset_x:     ox,
            pair_row_y:   row_y,
            foot_world_y: foot_y,
            pillow_mode:  nil,
            tally_stock:  false,
            upside_down:  spec[:upside_down],
            back_exclude:  excludes[:back],
            front_exclude: excludes[:front],
            back_highlight_part_names:  hl[:back],
            front_highlight_part_names: hl[:front],
            back_hidden_part_names:  hidden[:back],
            front_hidden_part_names: hidden[:front]
          )
        end
      end

      def extension_degree_bed_pairs(config, back_frame:, front_frame:)
        step = config.outer_width + config.pair_gap_x
        EXTENSION_SPECS.map do |spec|
          foot_y = foot_world_y_for(config, spec[:foot])
          hidden = resolve_hidden(spec[:variant], back_frame, front_frame, config)
          BedPair.new(
            config,
            back_frame:   back_frame,
            front_frame:  front_frame,
            back_name:    spec[:back_name],
            front_name:   spec[:front_name],
            offset_x:     spec[:column] * step,
            foot_world_y: foot_y,
            pillow_mode:  spec[:pillow_mode],
            tally_stock:  spec[:tally_stock],
            back_hidden_part_names:  hidden[:back],
            front_hidden_part_names: hidden[:front]
          )
        end
      end

      def resolve_excludes(variant, back_frame, front_frame, config)
        resolver = VARIANT_EXCLUDES[variant] ||
                   raise(ArgumentError, "Unknown assembly variant: #{variant.inspect}")
        resolver.call(back_frame, front_frame, config)
      end

      def highlights(key)
        case key
        when :under_slat_foot_end
          { back: [], front: BedPartGroups::FRONT_UNDER_SLAT_FOOT_BEAM.dup }
        when :head_and_foot_ledges
          { back: [LEDGE_HEAD], front: [LEDGE_FOOT] }
        when :none
          { back: [], front: [] }
        when :flip_outer_corner_legs
          { back:  BedPartGroups::FLIP_OUTER_CORNER_BACK_HIGHLIGHTS.dup,
            front: BedPartGroups::FLIP_OUTER_CORNER_FRONT_HIGHLIGHTS.dup }
        when :flip_head_foot_caps
          { back: ['EB | beam | head | cap'], front: ['EB | beam | foot | cap'] }
        when :flip_sub_assemblies
          { back:  BedPartGroups::FLIP_SUB_ASSEMBLY_BACK_HIGHLIGHTS.dup,
            front: BedPartGroups::FLIP_SUB_ASSEMBLY_FRONT_HIGHLIGHTS.dup }
        else
          raise ArgumentError, "Unknown construction highlight key: #{key.inspect}"
        end
      end

      def resolve_hidden(variant, back_frame, front_frame, config)
        return { back: [], front: [] } unless variant

        resolver = VARIANT_HIDDEN[variant] ||
                   raise(ArgumentError, "Unknown hidden variant: #{variant.inspect}")
        resolver.call(back_frame, front_frame, config)
      end

      def foot_world_y_for(config, key)
        case key
        when :extended  then config.extended_front_foot_world_y
        when :decoupled then config.decoupled_front_foot_world_y
        when :one_small then config.one_small_extension_front_foot_world_y
        when :halfway   then config.halfway_front_foot_world_y
        when :retracted then config.retracted_foot_world_y
        else
          raise ArgumentError, "Unknown foot preset: #{key.inspect}"
        end
      end
    end
  end
end
