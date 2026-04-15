# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # All design inputs in one place; every derived dimension is a plain `def`.
    # Nothing is a constant — pass a Config instance to every class that needs it.
    # SketchUp stores lengths internally as inches; use `.mm` literals throughout.
    #
    # Coordinate convention (matches original script):
    #   +Y  head → foot (extension direction)
    #   +Z  up
    #   +X  left → right when looking from head
    class Config
      # ── Primary inputs ────────────────────────────────────────────────────────
      attr_reader :back_slat_count   # must be a positive odd integer
      attr_reader :top_of_slats_z    # world +Z of the upper face of the comb slats
      attr_reader :length_extended   # fully-extended bed length (head to foot face)

      # ── Stock section ─────────────────────────────────────────────────────────
      attr_reader :beam_narrow       # 44 mm
      attr_reader :beam_wide         # 69 mm
      attr_reader :plank_thickness   # 18 mm — non-structural sheet panels
      attr_reader :pillow_thickness  # 100 mm — foam short edge

      # ── Layout ────────────────────────────────────────────────────────────────
      attr_reader :slat_gap          # gap between adjacent comb teeth (X)
      attr_reader :pair_gap_x        # side-by-side spacing between preview pairs

      # ── Stock planning ────────────────────────────────────────────────────────
      attr_reader :stock_bar_length  # standard bar length for cut planning
      attr_reader :stock_kerf_mm     # blade kerf between cuts (0 = no kerf)

      def initialize(
        back_slat_count:  9,
        top_of_slats_z:   260.mm,
        length_extended:  2000.mm,
        beam_narrow:      44.mm,
        beam_wide:        69.mm,
        plank_thickness:  18.mm,
        pillow_thickness: 120.mm,
        slat_gap:         3.mm,
        pair_gap_x:       600.mm,
        stock_bar_length: 2100.mm,
        stock_kerf_mm:    0.0
      )
        unless back_slat_count.is_a?(Integer) && back_slat_count.positive? && back_slat_count.odd?
          raise ArgumentError,
                "Config: back_slat_count must be a positive odd integer (got #{back_slat_count.inspect})"
        end

        @back_slat_count  = back_slat_count
        @top_of_slats_z   = top_of_slats_z
        @length_extended  = length_extended
        @beam_narrow      = beam_narrow
        @beam_wide        = beam_wide
        @plank_thickness  = plank_thickness
        @pillow_thickness = pillow_thickness
        @slat_gap         = slat_gap
        @pair_gap_x       = pair_gap_x
        @stock_bar_length = stock_bar_length
        @stock_kerf_mm    = stock_kerf_mm.to_f
      end

      # ── Slat geometry ─────────────────────────────────────────────────────────

      # Front comb has one fewer tooth than back (sits in back gaps).
      def front_slat_count = back_slat_count - 1

      # Outliner names for slat groups (matches `FrameAssembly#_back_slats` / `#_front_slats`).
      def back_slat_group_names
        (0...back_slat_count).map { |i| "EB | slat | back | #{i + 1}/#{back_slat_count}" }
      end

      def front_slat_group_names
        fc = front_slat_count
        (0...fc).map { |i| "EB | slat | front | #{i + 1}/#{fc}" }
      end

      # Slats: narrow face along X (bed width), wide face vertical (stiffer in bending).
      def slat_dx = beam_narrow
      def slat_dz = beam_wide

      # ── Beam / leg orientations ───────────────────────────────────────────────

      # End beams and cap beams: narrow along Y, wide vertical.
      def beam_y = beam_narrow
      def beam_z = beam_wide

      # Leg posts: wide along X (across comb), narrow along Y (parallel to slat run).
      def leg_x = beam_wide
      def leg_y = beam_narrow

      # ── Key lengths ───────────────────────────────────────────────────────────

      # Each frame half's slats span exactly half the extended length.
      def slat_length     = length_extended / 2
      def back_slat_run_y = slat_length + beam_y
      def front_slat_run_y = back_slat_run_y

      # Fully retracted: both slat runs overlapping + one beam depth at each end.
      def length_retracted = back_slat_run_y + beam_y

      # ── Bed width ─────────────────────────────────────────────────────────────

      def n_slats_x    = back_slat_count + front_slat_count
      def gaps_along_x = n_slats_x - 1
      def outer_width  = (n_slats_x * slat_dx) + (gaps_along_x * slat_gap)

      # ── Z chain ───────────────────────────────────────────────────────────────

      def z_slat_top    = top_of_slats_z
      def z_slat_bottom = z_slat_top - slat_dz

      # End beams share the same bottom Z as slats.
      def z_beam_bottom = z_slat_bottom

      # Legs stop here in the standard (inset) case.
      def leg_height = z_slat_bottom - beam_z
      alias z_leg_top leg_height

      # Outer corner legs extend through the cap band so the shortened cap bears on them.
      def outer_corner_leg_height = z_beam_bottom

      # Mid-run leg tops must clear the sister-beam bottom.
      def mid_run_leg_height = z_slat_bottom - beam_z

      # ── World Y positions for the front frame (sliding half) ──────────────────

      # Front foot at the far end when fully extended.
      def extended_front_foot_world_y = length_extended

      # Upside-down construction row: front half one small-pillow segment past nominal
      # extension (visible comb gap). Upright steps 1–3 use extended_front_foot_world_y.
      def decoupled_front_foot_world_y = length_extended + pillow_small_length

      # World Y offset for the construction-step preview row (headward of y=0).
      def construction_steps_row_y = -(length_extended + pair_gap_x)

      # Extra +X for the upside-down step: 180° about +Y mirrors local X, so the
      # group's geometry lies mostly left of its anchor; shift by outer_width so it
      # clears the previous construction column (same row_y).
      def construction_flip_extra_offset_x = outer_width

      # Part names for upside-down construction step (blue leg callouts).
      FLIP_STEP_BACK_LEG_HIGHLIGHTS = [
        'EB | leg | head | -X',
        'EB | leg | head | +X',
        'EB | leg | head | -X | inset',
        'EB | leg | head | +X | inset',
        'EB | leg | mid run | -X',
        'EB | leg | mid run | +X',
        'EB | leg | post | behind head | -X',
        'EB | leg | post | behind head | +X',
        'EB | leg | post | behind mid | -X | headward',
        'EB | leg | post | behind mid | +X | headward',
        'EB | leg | post | mid tie filler | -X',
        'EB | leg | post | mid tie filler | +X'
      ].freeze
      FLIP_STEP_FRONT_LEG_HIGHLIGHTS = [
        'EB | leg | foot | -X',
        'EB | leg | foot | +X',
        'EB | leg | foot | -X | inset',
        'EB | leg | foot | +X | inset'
      ].freeze

      # Step 6 (no caps): blue callouts for outer sisters, sister ties, front rigidity.
      FLIP_NOCAPS_BACK_BRACE_HIGHLIGHTS = [
        'EB | beam | sister | outer -X',
        'EB | beam | sister | outer +X',
        'EB | beam | head tie | between sisters',
        'EB | beam | mid tie | between sisters'
      ].freeze
      FLIP_NOCAPS_FRONT_BRACE_HIGHLIGHTS = [
        'EB | beam | front | rigidity | below foot cap'
      ].freeze

      # Step 7: blue every `EB | beam |` child that exists (omitted geometry is skipped).
      FLIP_NOBRACE_BACK_BEAM_HIGHLIGHTS = [
        'EB | beam | head | cap',
        'EB | beam | head | end',
        'EB | beam | sister | outer -X',
        'EB | beam | sister | outer +X',
        'EB | beam | head tie | between sisters',
        'EB | beam | mid tie | between sisters'
      ].freeze
      FLIP_NOBRACE_FRONT_BEAM_HIGHLIGHTS = [
        'EB | beam | foot | cap',
        'EB | beam | foot | end',
        'EB | beam | front | under slats | foot end',
        'EB | beam | front | rigidity | below foot cap'
      ].freeze

      # Front foot position when retracted (outer face of front end beam).
      def retracted_foot_world_y = length_retracted + beam_narrow

      # ── Pillows ───────────────────────────────────────────────────────────────

      # Big pillow spans the retracted length; three equal smalls share the full span.
      # Extended layout (foot→head): small | 1, big, small | 2, small | 3.
      def pillow_big_length   = length_retracted + beam_narrow
      def small_pillow_count  = 3
      def pillow_small_length = (length_extended - length_retracted - beam_narrow) / small_pillow_count

      # Half-extended preview: front foot is one small cushion short of full extension.
      def halfway_front_foot_world_y = length_extended - pillow_small_length

      # Ext1 preview: retracted + one small flat’s worth of extension (3 sm total still defined).
      def one_small_extension_front_foot_world_y = retracted_foot_world_y + pillow_small_length

      # ── Cap geometry ─────────────────────────────────────────────────────────

      # Head/foot cap: starts at inner face of outer corner leg, spans to the other.
      def cap_x0 = leg_x
      def cap_dx = outer_width - (2 * leg_x)

      # ── Section tolerance (mm) ────────────────────────────────────────────────

      SECTION_TOL_MM = 0.01

      # Returns true if +len+ matches either section side (narrow or wide).
      def section_match?(len)
        v = len.to_mm.abs
        (v - beam_narrow.to_mm).abs < SECTION_TOL_MM ||
          (v - beam_wide.to_mm).abs  < SECTION_TOL_MM
      end

      # Returns the extrusion length in mm (the one dimension that is NOT a section side).
      # Raises if the three dimensions don't describe a valid 44×69 prism.
      def extrusion_length_mm(dx, dy, dz)
        dims = [dx, dy, dz]
        unless dims.count { |d| section_match?(d) } == 2
          got = dims.map { |d| format('%.2f mm', d.to_mm) }.join(', ')
          raise ArgumentError,
                "Stock beam: need two section sides (#{beam_narrow.to_mm.round(2)} × #{beam_wide.to_mm.round(2)} mm), got (#{got})"
        end

        long = dims.find { |d| !section_match?(d) }
        mm   = long.to_mm.abs
        raise ArgumentError, 'Stock beam: extrusion length must be > 0' if mm <= SECTION_TOL_MM

        mm
      end

      # ── SketchUp layer / material names (stable, used across classes) ─────────

      LAYER_NAME          = 'EB_ExtendableBed'
      ATTR_DICT           = 'Timmerman::ExtendableBed'
      PREVIEW_MAT_BACK    = 'EB preview | back'
      PREVIEW_MAT_FRONT   = 'EB preview | front'
      PREVIEW_RGB_BACK    = [188, 152, 106].freeze
      PREVIEW_RGB_FRONT   = [168, 130,  90].freeze
      PREVIEW_RGB_ACTIVE  = [56, 119, 234].freeze

      # ── Outliner group names for the four preview pairs ───────────────────────

      GROUP_EXT_BACK     = 'EB_Ext_Back'
      GROUP_EXT_FRONT    = 'EB_Ext_Front'
      GROUP_EXT1_BACK    = 'EB_Ext1_Back'
      GROUP_EXT1_FRONT   = 'EB_Ext1_Front'
      GROUP_HALF_BACK    = 'EB_Half_Back'
      GROUP_HALF_FRONT   = 'EB_Half_Front'
      GROUP_RET_BACK     = 'EB_Ret_Back'
      GROUP_RET_FRONT    = 'EB_Ret_Front'
      GROUP_RETGND_BACK  = 'EB_RetGnd_Back'
      GROUP_RETGND_FRONT = 'EB_RetGnd_Front'

      GROUP_STEP_EXT_BACK        = 'EB_StepExt_Back'
      GROUP_STEP_EXT_FRONT       = 'EB_StepExt_Front'
      GROUP_STEP_DECOUP_BACK     = 'EB_StepDecoup_Back'
      GROUP_STEP_DECOUP_FRONT    = 'EB_StepDecoup_Front'
      GROUP_STEP_NOLEDGES_BACK   = 'EB_StepNoLedges_Back'
      GROUP_STEP_NOLEDGES_FRONT  = 'EB_StepNoLedges_Front'
      GROUP_STEP_FLIP_BACK       = 'EB_StepFlip_Back'
      GROUP_STEP_FLIP_FRONT      = 'EB_StepFlip_Front'
      GROUP_STEP_FLIP_NOLEGS_BACK  = 'EB_StepFlipNoLegs_Back'
      GROUP_STEP_FLIP_NOLEGS_FRONT = 'EB_StepFlipNoLegs_Front'
      GROUP_STEP_FLIP_NOCAPS_BACK  = 'EB_StepFlipNoCaps_Back'
      GROUP_STEP_FLIP_NOCAPS_FRONT = 'EB_StepFlipNoCaps_Front'
      GROUP_STEP_FLIP_NOBRACE_BACK   = 'EB_StepFlipNoBrace_Back'
      GROUP_STEP_FLIP_NOBRACE_FRONT  = 'EB_StepFlipNoBrace_Front'

      # Matches any auto-generated EB pair root group name.
      GROUP_NAME_RE = /\AEB_(Ext|Ext1|Ret|Half|RetGnd|StepExt|StepDecoup|StepNoLedges|StepFlip|StepFlipNoLegs|StepFlipNoCaps|StepFlipNoBrace)_(Back|Front)\z/

      # Single-pair root names (cleared together with the multi-pair preview set).
      SINGLE_PAIR_ROOTS = %w[EB_Back EB_Front].freeze

      # Written on each successful BedLayout#create (named-group geometry snapshot).
      GEOMETRY_BASELINE_JSON =
        File.expand_path('../references/extendable_bed_geometry_baseline.json', __dir__).freeze

      # Design-reference copies placed manually in the model — cleared must NOT touch these.
      REFERENCE_ROOT_RE = /\A(?:NEW|New)_EB_Ext_(Back|Front)\z/

      # ── Part-name prefixes and regexes ───────────────────────────────────────

      PLANK_NAME_RE  = /\AEB \| plank \|/
      PILLOW_NAME_RE = /\AEB \| pillow \|/
      # Beams and legs only (excludes slats) — used by the AABB validator.
      SOLID_NAME_RE  = /\AEB \| (beam|leg) \|/

      # Nested part-group names to erase on clear (previous labels after part renames).
      PURGE_NESTED_PART_GROUP_NAMES = %w[
        EB | beam | behind leg | mid -X
        EB | beam | behind leg | mid +X
        EB | beam | behind leg | head -X
        EB | beam | behind leg | head +X
        EB | beam | behind leg | mid -X | headward
        EB | beam | behind leg | mid +X | headward
        EB | beam | mid tie | vertical filler | -X
        EB | beam | mid tie | vertical filler | +X
      ].freeze
    end
  end
end
