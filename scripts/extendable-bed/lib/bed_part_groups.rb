# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Semantic name-list constants for exclude/include composition in
    # construction-step variants. Each group is a small frozen list of
    # part names — compose freely via array concatenation.
    #
    # Used by +construction_steps.rb+ to build the +VARIANT_EXCLUDES+ table
    # and by +BedPairCatalog.highlights+.
    module BedPartGroups
      # ── Back frame ──────────────────────────────────────────────────────

      BACK_HEAD_OUTER_CORNERS = [
        'EB | leg | head | -X',
        'EB | leg | head | +X'
      ].freeze

      BACK_HEAD_INSETS = [
        'EB | leg | head | -X | inset',
        'EB | leg | head | +X | inset'
      ].freeze

      BACK_HEAD_POSTS = [
        'EB | leg | post | behind head | -X',
        'EB | leg | post | behind head | +X'
      ].freeze

      BACK_MID_LEGS = [
        'EB | leg | mid run | -X',
        'EB | leg | mid run | +X'
      ].freeze

      BACK_MID_POSTS = [
        'EB | leg | post | behind mid | -X',
        'EB | leg | post | behind mid | +X'
      ].freeze

      BACK_HEAD_CAP   = ['EB | beam | head | cap'].freeze
      BACK_HEAD_LEDGE = ['EB | plank | head | ledge'].freeze

      BACK_SISTERS = [
        'EB | beam | back | sister | -X',
        'EB | beam | back | sister | +X'
      ].freeze
      BACK_SISTER_TIE = ['EB | beam | back | sister tie'].freeze
      BACK_UNDER_SLAT_SUPPORT = ['EB | beam | back | under slat support'].freeze

      # ── Front frame ─────────────────────────────────────────────────────

      FRONT_FOOT_OUTER_CORNERS = [
        'EB | leg | foot | -X',
        'EB | leg | foot | +X'
      ].freeze

      FRONT_FOOT_INSETS = [
        'EB | leg | foot | -X | inset',
        'EB | leg | foot | +X | inset'
      ].freeze

      FRONT_FOOT_CAP   = ['EB | beam | foot | cap'].freeze
      FRONT_FOOT_LEDGE = ['EB | plank | foot | ledge'].freeze

      FRONT_UNDER_SLAT_FOOT_BEAM = ['EB | beam | front | under slat foot'].freeze

      # ── Composite groups (aliases for common combinations) ──────────────

      BACK_ALL_LEGS = (
        BACK_HEAD_OUTER_CORNERS + BACK_HEAD_INSETS +
        BACK_HEAD_POSTS + BACK_MID_LEGS + BACK_MID_POSTS
      ).freeze

      FRONT_ALL_LEGS = (
        FRONT_FOOT_OUTER_CORNERS + FRONT_FOOT_INSETS
      ).freeze

      # Sub-assembly whitelists used by the step-1 "sub-assembly prep" variant.
      # The mid tie bridges the two outer-sister sub-assemblies so the sister
      # cluster is preassembled as one unit before meeting the slats.
      PREP_BACK_HEAD_CAP_SUB = (BACK_HEAD_CAP + BACK_HEAD_OUTER_CORNERS + BACK_HEAD_INSETS).freeze

      PREP_BACK_SISTER_MX_SUB = [
        'EB | beam | back | sister | -X',
        'EB | leg | post | behind head | -X',
        'EB | leg | post | behind mid | -X',
        'EB | leg | mid run | -X'
      ].freeze
      PREP_BACK_SISTER_PX_SUB = [
        'EB | beam | back | sister | +X',
        'EB | leg | post | behind head | +X',
        'EB | leg | post | behind mid | +X',
        'EB | leg | mid run | +X'
      ].freeze

      PREP_BACK_WHITELIST = (
        PREP_BACK_HEAD_CAP_SUB +
        PREP_BACK_SISTER_MX_SUB +
        PREP_BACK_SISTER_PX_SUB +
        BACK_SISTER_TIE
      ).freeze

      # Front: foot cap only (foot inset legs omitted — they appear from step 4).
      PREP_FRONT_WHITELIST = FRONT_FOOT_CAP.freeze

      # Step-2 "fork (slats + end beams only)" whitelists — depend on slat count.
      # Consumers call +.fork_back_whitelist(config)+ etc. to include the config's
      # slat names.
      module_function

      def fork_back_whitelist(config)
        config.back_slat_group_names
      end

      def fork_front_whitelist(config)
        config.front_slat_group_names
      end

      def fork_gap_helper_names(config)
        max_count = [config.fork_gap_helper_count, [config.back_slat_count - 1, 0].max].min
        (0...max_count).map { |i| "EB | helper | fork gap | #{i + 1}/#{max_count}" }
      end

      # Step 3 +flip_sub_assemblies+ highlight: back sub-assembly cluster; front
      # foot cap only (foot inset legs hidden in steps 1 and 3).
      FLIP_SUB_ASSEMBLY_BACK_HIGHLIGHTS = (
        BACK_HEAD_OUTER_CORNERS + BACK_HEAD_INSETS + BACK_MID_LEGS +
        BACK_HEAD_POSTS + BACK_MID_POSTS +
        BACK_HEAD_CAP + BACK_SISTERS + BACK_SISTER_TIE
      ).freeze
      FLIP_SUB_ASSEMBLY_FRONT_HIGHLIGHTS = FRONT_FOOT_CAP.freeze

      # Step-4 highlight: foot outer corner legs (the ones about to be removed).
      FLIP_OUTER_CORNER_BACK_HIGHLIGHTS  = [].freeze
      FLIP_OUTER_CORNER_FRONT_HIGHLIGHTS = FRONT_FOOT_OUTER_CORNERS
    end
  end
end
