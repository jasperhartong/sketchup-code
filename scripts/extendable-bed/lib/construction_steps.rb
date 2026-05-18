# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Declarative tables for preview BedPair instances:
    #   — 8 construction-assembly steps (headward row, progressive omissions)
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
        # Step 7: full bed, nothing hidden.
        construction_full: ->(_b, _f, _c) { { back: [], front: [] } },

        # Step 6: ledges removed, under-slat extension stop retained.
        construction_no_ledges_with_beam: ->(_b, _f, _c) {
          { back:  G::BACK_HEAD_LEDGE,
            front: G::FRONT_FOOT_LEDGE }
        },

        # Ledges + under-slat extension stop all gone.
        construction_no_ledges: ->(_b, _f, _c) {
          { back:  G::BACK_HEAD_LEDGE,
            front: G::FRONT_FOOT_LEDGE + G::FRONT_UNDER_SLAT_EXTENSION_STOP }
        },

        # Step 3: also remove foot outer corners (they aren't part of the
        # step-1 sub-assembly, unlike the head outer corners).
        flip_no_legs: ->(_b, _f, _c) {
          { back:  G::BACK_HEAD_LEDGE,
            front: G::FRONT_FOOT_LEDGE + G::FRONT_UNDER_SLAT_EXTENSION_STOP +
                   G::FRONT_FOOT_OUTER_CORNERS + G::FRONT_FOOT_INSETS }
        },

        # Step 2: keep only slats + end beams (forking preview). Exclude = full − whitelist.
        # Also include gap helpers to help with construction
        flip_no_caps: ->(b, f, c) {
          back_keep  = G.fork_back_whitelist(c) + G.fork_gap_helper_names(c)
          front_keep = G.fork_front_whitelist(c) + G.fork_gap_helper_names(c)
          { back:  b.names - back_keep,
            front: f.names - front_keep }
        },

        # Step 1: cap sub-assemblies + both sister sub-assemblies joined by the mid tie.
        sub_assembly_prep: ->(b, f, _c) {
          { back:  b.names - G::PREP_BACK_WHITELIST,
            front: f.names - G::PREP_FRONT_WHITELIST }
        }
      }.freeze

      VARIANT_HIDDEN = {
        # Step 1 cleanup: hide selected mirrored screw pairs to keep the
        # sub-assembly prep view uncluttered.
        step_prep_hide_conflicting_screws: ->(_b, _f, c) {
          {
            back: [
              'EB | screw | back sister -X | under headward 2',
              'EB | screw | back sister -X | under headward 1',
              'EB | screw | back sister -X | middle',
              'EB | screw | back sister -X | under footward 1',
              'EB | screw | back sister -X | under footward 2',
              'EB | screw | back sister +X | under headward 2',
              'EB | screw | back sister +X | under headward 1',
              'EB | screw | back sister +X | middle',
              'EB | screw | back sister +X | under footward 1',
              'EB | screw | back sister +X | under footward 2',
              "EB | screw | sister tie | 8/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 2/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 7/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 3/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 6/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 4/#{c.back_slat_count} | heart",
              "EB | screw | sister tie | 5/#{c.back_slat_count} | heart",
              "EB | screw | head cap | 8/#{c.back_slat_count} | heart",
              "EB | screw | head cap | 2/#{c.back_slat_count} | heart",
              "EB | screw | head cap | 7/#{c.back_slat_count} | heart",
              "EB | screw | head cap | 3/#{c.back_slat_count} | heart",
              "EB | screw | head cap | 6/#{c.back_slat_count} | heart",
              "EB | screw | head cap | 4/#{c.back_slat_count} | heart",
              "EB | screw | head cap | 5/#{c.back_slat_count} | heart"
            ],
            front: (1..c.front_slat_count).map { |n|
              "EB | screw | foot cap | #{n}/#{c.front_slat_count} | heart"
            }
          }
        },

      }.freeze

      LEDGE_HEAD = 'EB | plank | head | ledge'
      LEDGE_FOOT = 'EB | plank | foot | ledge'

      CONSTRUCTION_SPECS = [
        # Order and visual position now both follow step-number order (1..8).
        { back_name: Config::GROUP_STEP1_BACK, front_name: Config::GROUP_STEP1_FRONT, column: 0, foot: :decoupled, upside_down: true,  variant: :sub_assembly_prep,                 helper: :hidden, hidden_variant: :step_prep_hide_conflicting_screws },
        { back_name: Config::GROUP_STEP2_BACK, front_name: Config::GROUP_STEP2_FRONT, column: 1, foot: :decoupled, upside_down: true,  variant: :flip_no_caps,                      helper: :show },
        { back_name: Config::GROUP_STEP3_BACK, front_name: Config::GROUP_STEP3_FRONT, column: 2, foot: :decoupled, upside_down: true,  variant: :flip_no_legs,                      helper: :hidden },
        { back_name: Config::GROUP_STEP4_BACK, front_name: Config::GROUP_STEP4_FRONT, column: 3, foot: :decoupled, upside_down: true,  variant: :construction_no_ledges,           helper: :hidden },
        { back_name: Config::GROUP_STEP5_BACK, front_name: Config::GROUP_STEP5_FRONT, column: 4, foot: :extended,  upside_down: true,  variant: :construction_no_ledges_with_beam, helper: :hidden },
        { back_name: Config::GROUP_STEP6_BACK, front_name: Config::GROUP_STEP6_FRONT, column: 5, foot: :extended,  upside_down: false, variant: :construction_no_ledges_with_beam, helper: :hidden },
        { back_name: Config::GROUP_STEP7_BACK, front_name: Config::GROUP_STEP7_FRONT, column: 6, foot: :extended,  upside_down: false, variant: :construction_full,              helper: :hidden },
        { back_name: Config::GROUP_STEP8_BACK, front_name: Config::GROUP_STEP8_FRONT, column: 7, foot: :retracted, upside_down: false, variant: :construction_full,              helper: :hidden }
      ].freeze

      EXTENSION_SPECS = [
        { back_name: Config::GROUP_RET_BACK, front_name: Config::GROUP_RET_FRONT, column: 0, foot: :retracted,
          pillow_mode: :retracted, tally_stock: false, display_name: Config::PREVIEW_NAME_RET },
        { back_name: Config::GROUP_EXT1_BACK, front_name: Config::GROUP_EXT1_FRONT, column: 1, foot: :one_small,
          pillow_mode: :extended_one_small, tally_stock: false, display_name: Config::PREVIEW_NAME_EXT1 },
        { back_name: Config::GROUP_EXT_BACK, front_name: Config::GROUP_EXT_FRONT, column: 2, foot: :extended,
          pillow_mode: :extended, tally_stock: true, display_name: Config::PREVIEW_NAME_EXT },
        { back_name: Config::GROUP_RETGND_BACK, front_name: Config::GROUP_RETGND_FRONT, column: 3, foot: :retracted,
          pillow_mode: :retracted_gnd, tally_stock: false, display_name: Config::PREVIEW_NAME_RETGND }
      ].freeze

      module_function

      def construction_bed_pairs(config, back_frame:, front_frame:)
        step   = config.preview_column_step
        flip_x = config.construction_flip_extra_offset_x
        row_y  = config.construction_steps_row_y

        CONSTRUCTION_SPECS.map do |spec|
          col     = spec[:column]
          ox      = (col * step) + (spec[:upside_down] ? flip_x : 0)
          foot_y  = foot_world_y_for(config, spec[:foot])
          excludes = resolve_excludes(spec[:variant], back_frame, front_frame, config)
          helper_excludes = helper_excludes(spec[:helper], config)
          excludes = {
            back:  excludes[:back] + helper_excludes[:back],
            front: excludes[:front] + helper_excludes[:front]
          }
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
            scene_key:    :construction,
            back_exclude:  excludes[:back],
            front_exclude: excludes[:front],
            back_hidden_part_names:  hidden[:back],
            front_hidden_part_names: hidden[:front]
          )
        end
      end

      def extension_degree_bed_pairs(config, back_frame:, front_frame:)
        step = config.preview_column_step
        EXTENSION_SPECS.map do |spec|
          row_y = config.extension_preview_row_y
          scene_key = :variants
          foot_y = foot_world_y_for(config, spec[:foot])
          hidden = resolve_hidden(spec[:variant], back_frame, front_frame, config)
          helper_names = BedPartGroups.fork_gap_helper_names(config)
          BedPair.new(
            config,
            back_frame:   back_frame,
            front_frame:  front_frame,
            back_name:    spec[:back_name],
            front_name:   spec[:front_name],
            offset_x:     spec[:column] * step,
            pair_row_y:   row_y,
            foot_world_y: foot_y,
            pillow_mode:  spec[:pillow_mode],
            tally_stock:  spec[:tally_stock],
            display_name: spec[:display_name],
            scene_key:    scene_key,
            back_hidden_part_names:  hidden[:back] + helper_names,
            front_hidden_part_names: hidden[:front] + helper_names
          )
        end
      end

      def resolve_excludes(variant, back_frame, front_frame, config)
        resolver = VARIANT_EXCLUDES[variant] ||
                   raise(ArgumentError, "Unknown assembly variant: #{variant.inspect}")
        resolver.call(back_frame, front_frame, config)
      end

      def resolve_hidden(variant, back_frame, front_frame, config)
        return { back: [], front: [] } unless variant

        resolver = VARIANT_HIDDEN[variant] ||
                   raise(ArgumentError, "Unknown hidden variant: #{variant.inspect}")
        resolver.call(back_frame, front_frame, config)
      end

      def helper_excludes(key, config)
        names = BedPartGroups.fork_gap_helper_names(config)
        case key
        when :show
          { back: [], front: [] }
        when :hidden, nil
          { back: names, front: names }
        else
          raise ArgumentError, "Unknown helper style key: #{key.inspect}"
        end
      end

      def foot_world_y_for(config, key)
        case key
        when :extended  then config.extended_front_foot_world_y
        when :decoupled then config.decoupled_front_foot_world_y
        when :one_small then config.one_small_extension_front_foot_world_y
        when :retracted then config.retracted_foot_world_y
        else
          raise ArgumentError, "Unknown foot preset: #{key.inspect}"
        end
      end
    end
  end
end
