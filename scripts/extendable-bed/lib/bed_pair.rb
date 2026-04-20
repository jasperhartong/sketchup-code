# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # One preview: a placement of the *shared* BackFrame and FrontFrame
    # catalogs at a specific world position, with optional part exclusions
    # (per frame) and a pillow-mode selection.
    #
    # The frame catalogs themselves live on BedLayout and are shared across
    # every BedPair — BedPair only owns *views* (exclusions + group name)
    # and mode-specific pillow sets.
    class BedPair
      attr_reader :back_name, :front_name, :offset_x, :pair_row_y, :foot_world_y,
                  :pillow_mode, :tally_stock, :upside_down,
                  :back_highlight_part_names, :front_highlight_part_names,
                  :back_exclude, :front_exclude

      # @param back_frame  [BackFrame]    shared catalog instance (one per Config)
      # @param front_frame [FrontFrame]   shared catalog instance (one per Config)
      # @param back_exclude  [Array<String>] part names to hide in the back view for this preview
      # @param front_exclude [Array<String>] part names to hide in the front view for this preview
      # @param back_highlight_part_names  [Array<String>] painted with PREVIEW_RGB_ACTIVE after render
      # @param front_highlight_part_names [Array<String>]
      # @param pillow_mode [Symbol, nil]  see +PillowSets+ for allowed values
      # @param tally_stock [Boolean]     when true, this pair's beams count toward the cut list
      # @param upside_down [Boolean]     when true, root is rotated 180° about +Y (construction flip row)
      def initialize(config,
                     back_frame:,
                     front_frame:,
                     back_name:,
                     front_name:,
                     offset_x:,
                     foot_world_y:,
                     pair_row_y: 0,
                     pillow_mode: nil,
                     tally_stock: true,
                     upside_down: false,
                     back_exclude: [],
                     front_exclude: [],
                     back_highlight_part_names: [],
                     front_highlight_part_names: [])
        @config       = config
        @back_frame_catalog  = back_frame
        @front_frame_catalog = front_frame
        @back_name    = back_name
        @front_name   = front_name
        @offset_x     = offset_x
        @pair_row_y   = pair_row_y
        @foot_world_y = foot_world_y
        @pillow_mode  = pillow_mode
        @tally_stock  = tally_stock
        @upside_down  = upside_down
        @back_exclude  = back_exclude.dup.freeze
        @front_exclude = front_exclude.dup.freeze
        @back_highlight_part_names  = back_highlight_part_names.dup.freeze
        @front_highlight_part_names = front_highlight_part_names.dup.freeze
      end

      # ── Render-time views over the shared frame catalogs ─────────────────

      def back_view
        @back_frame_catalog.view(group_name: @back_name, exclude: @back_exclude)
      end

      def front_view
        @front_frame_catalog.view(group_name: @front_name, exclude: @front_exclude)
      end

      # ── Pillow sets (catalogs) for this pair's mode ──────────────────────

      def back_pillow_set
        PillowSets::BackPillowSet.new(@config, mode: @pillow_mode)
      end

      def front_pillow_set
        PillowSets::FrontPillowSet.new(@config, mode: @pillow_mode, foot_world_y: @foot_world_y)
      end
    end
  end
end
