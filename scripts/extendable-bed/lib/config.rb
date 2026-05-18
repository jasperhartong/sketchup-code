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
      attr_reader :usable_length_extended  # fully-extended usable slat bottom (head → foot)
      attr_reader :usable_length_retracted # retracted usable slat bottom (head → foot, y = 0 … foot)

      # ── Stock section ─────────────────────────────────────────────────────────
      attr_reader :beam_narrow       # 44 mm
      attr_reader :beam_wide         # 69 mm
      attr_reader :plank_thickness   # 18 mm — non-structural sheet panels
      attr_reader :pillow_thickness  # 100 mm — foam short edge

      # XY footprint corner radius before Z push/pull on catalog beams (Beam/Leg/Slat) and pillows.
      attr_reader :beam_box_corner_radius
      attr_reader :plank_box_corner_radius
      attr_reader :pillow_box_corner_radius
      attr_reader :beam_box_corner_axis
      attr_reader :plank_box_corner_axis
      attr_reader :pillow_box_corner_axis

      # ── Layout ────────────────────────────────────────────────────────────────
      attr_reader :slat_gap          # gap between adjacent comb teeth (X)
      attr_reader :pair_gap_x        # side-by-side spacing between preview pairs
      attr_reader :preview_band_gap  # empty space between preview rows (variants, screws, steps, cut plan)

      # ── Stock planning ────────────────────────────────────────────────────────
      attr_reader :stock_bar_length  # standard bar length for cut planning
      attr_reader :stock_kerf_mm     # blade kerf between cuts (0 = no kerf)

      # Bulk density for estimated bed mass from tallied solid wood (beams/legs/slats + planks).
      # kg/m³ — oven-dry typical construction pine is often ~450–550; adjust for your actual species.
      attr_reader :wood_density_kg_m3

      # Debug rendering mode:
      #   :off              => preview wood tone on all structural parts
      #   :sides            => axis-face colors
      #   :components_reuse => shared color per component definition
      #   :overlaps         => wood preview + magenta on AABB-overlapping parts
      attr_reader :debug_color

      # When false, only the countersink pocket is cut; the shaft through-hole step is skipped
      # (avoids SketchUp deleting the host on some pocket floor orientations).
      attr_reader :hardware_through_hole

      # When false, no boolean-style cuts are applied to host parts (only screw mesh is added).
      attr_reader :hardware_cut_hosts

      # When true, cut countersink pocket then through hole; when false, a single through hole only.
      attr_reader :hardware_countersink_first

      # When true, clear() also purges unused component definitions after root erase.
      attr_reader :purge_unused_definitions

      # When true, render the stock cut plan as 3D bars in the model.
      attr_reader :show_cut_plan_3d

      def initialize(
        back_slat_count:  9,
        top_of_slats_z:   260.mm,
        usable_length_extended:  2000.mm,
        usable_length_retracted: 1100.mm,
        beam_narrow:      44.mm,
        beam_wide:        69.mm,
        plank_thickness:  18.mm,
        pillow_thickness: 120.mm,
        beam_box_corner_radius:   5.mm,
        plank_box_corner_radius:  2.mm,
        pillow_box_corner_radius: 30.mm,
        beam_box_corner_axis: :long,
        plank_box_corner_axis: :long,
        pillow_box_corner_axis: :short,
        slat_gap:         3.mm,
        pair_gap_x:       600.mm,
        preview_band_gap: 3600.mm,
        stock_bar_length: 2700.mm,
        stock_kerf_mm: 0.0,
        wood_density_kg_m3: 500.0,
        debug_color: :off,
        hardware_through_hole: true,
        hardware_cut_hosts: false,
        hardware_countersink_first: false,
        purge_unused_definitions: false,
        show_cut_plan_3d: true
      )
        unless back_slat_count.is_a?(Integer) && back_slat_count.positive? && back_slat_count.odd?
          raise ArgumentError,
                "Config: back_slat_count must be a positive odd integer (got #{back_slat_count.inspect})"
        end

        @back_slat_count  = back_slat_count
        @top_of_slats_z   = top_of_slats_z
        @usable_length_extended  = usable_length_extended
        @usable_length_retracted = usable_length_retracted
        if usable_length_retracted >= usable_length_extended
          raise ArgumentError,
                'Config: usable_length_retracted must be less than usable_length_extended ' \
                "(got #{usable_length_retracted.to_mm.round(1)} mm vs #{usable_length_extended.to_mm.round(1)} mm)"
        end
        @beam_narrow      = beam_narrow
        @beam_wide        = beam_wide
        @plank_thickness  = plank_thickness
        @pillow_thickness = pillow_thickness
        @beam_box_corner_radius   = beam_box_corner_radius
        @plank_box_corner_radius  = plank_box_corner_radius
        @pillow_box_corner_radius = pillow_box_corner_radius
        @beam_box_corner_axis   = _resolve_corner_axis(beam_box_corner_axis)
        @plank_box_corner_axis  = _resolve_corner_axis(plank_box_corner_axis)
        @pillow_box_corner_axis = _resolve_corner_axis(pillow_box_corner_axis)
        @slat_gap         = slat_gap
        @pair_gap_x       = pair_gap_x
        @preview_band_gap = preview_band_gap
        @stock_bar_length = stock_bar_length
        @stock_kerf_mm    = stock_kerf_mm.to_f
        @wood_density_kg_m3 = wood_density_kg_m3.to_f
        @debug_color = _resolve_debug_color(debug_color)
        @hardware_through_hole = hardware_through_hole ? true : false
        @hardware_cut_hosts = hardware_cut_hosts ? true : false
        @hardware_countersink_first = hardware_countersink_first ? true : false
        @purge_unused_definitions = purge_unused_definitions ? true : false
        @show_cut_plan_3d = show_cut_plan_3d ? true : false
      end

      def _resolve_debug_color(debug_color)
        mode = debug_color.to_sym
        return mode if %i[off sides components_reuse overlaps].include?(mode)

        raise ArgumentError,
              'Config: debug_color must be one of :off, :sides, :components_reuse, :overlaps ' \
              "(got #{debug_color.inspect})"
      end

      def _resolve_corner_axis(axis)
        mode = axis.to_sym
        return mode if %i[long short x y z].include?(mode)

        raise ArgumentError, "Config: corner axis must be one of :long, :short, :x, :y, :z (got #{axis.inspect})"
      end

      # Catalog of screw families for hardware rendering (visual / design intent).
      # :eb_pocket_4mm supports multiple shaft lengths so specific placements can
      # opt into shorter screws via `shaft_length_index` (default index 0).
      # @return [Hash{Symbol=>SketchupUtils::Hardware::ScrewSpec}]
      def screw_specs
        shaft = 80.mm
        short_shaft = 50.mm
        @screw_specs ||= {
          :eb_pocket_4mm => SketchupUtils::Hardware::ScrewSpec.new(
            :eb_pocket_4mm,
            shaft_diameter:       4.2.mm,
            shaft_lengths:        [shaft, short_shaft],
            head_diameter:        8.mm,
            head_height:          2.2.mm,
            countersink_diameter: 8.5.mm,
            countersink_depth:   2.5.mm
          )
        }.freeze
      end

      # ── Slat geometry ─────────────────────────────────────────────────────────

      # Front comb has one fewer tooth than back (sits in back gaps).
      def front_slat_count = back_slat_count - 1

      # Number of gap helpers per preview pair (depends on slat count).
      def fork_gap_helper_count = back_slat_count - 1

      # Outliner names for slat groups (matches `FrameAssembly#_back_slats` / `#_front_slats`).
      def back_slat_group_names
        (0...back_slat_count).map { |i| "EB | slat | back | #{i + 1}/#{back_slat_count}" }
      end

      def front_slat_group_names
        fc = front_slat_count
        (0...fc).map { |i| "EB | slat | front | #{i + 1}/#{fc}" }
      end

      # Head tie → middle back slats: pocket axis tilt (degrees) from the face **outward normal**
      # toward `pocket_tilt_toward: :pos_v` (+foot on :max_z). Matches a typical ~15° pocket jig.
      def head_tie_slat_pocket_tilt_deg = 15.0

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

      # Retracted comb overlap depth (head slat face → back slat footward end, before narrow foot stock).
      def retracted_frame_depth_y = usable_length_retracted - beam_narrow

      # Comb tooth run and back slat Y span derived from usable_length_retracted (slat_length + 2·beam_y + beam_narrow).
      def slat_length     = retracted_frame_depth_y - (2 * beam_y)
      def back_slat_run_y = slat_length + beam_y

      # Back slat solids span y ∈ [0, back_slat_part_depth_y); footward face at usable_length_retracted
      # (front frame y = 0 when translated by retracted_foot_world_y).
      def back_slat_part_depth_y = usable_length_retracted

      # Back head cap on the fixed frame (matches +BackFrame#y_head+ / head cap placement).
      def back_head_cap_y0 = -plank_thickness
      def back_head_cap_max_world_y = back_head_cap_y0 + beam_wide

      # Extension stop headward limit when retracted: footward of head cap (no cap overlap).
      def front_extension_stop_y0 = back_head_cap_max_world_y - usable_length_retracted

      # +Y width = comb overlap left between retracted clearance and extended mid-tie meet.
      def extension_stop_plank_width
        mid_tie_y0 - usable_length_extended - front_extension_stop_y0
      end

      # Retracted: slat bears on head cap but clears head ledge (ledge spans cap y₀…y₀+plank_thickness).
      def back_head_ledge_max_world_y = back_head_cap_y0 + plank_thickness

      def front_slat_y0_at_retracted_on_head_cap = back_head_ledge_max_world_y - usable_length_retracted

      def front_slat_y0 = [front_slat_y0_at_retracted_on_head_cap, front_extension_stop_y0].min

      def front_slat_y1 = 0
      def front_slat_run_y = front_slat_y1 - front_slat_y0

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

      # Mid-run leg tops align with the bottom of outer sister / tie beams (flat on wide face → 44 mm tall).
      def mid_run_leg_height = z_slat_bottom - beam_narrow

      # Foot cap min_y and foot corner/inset leg min_y (dy = beam_wide each): same sandwich as head cap vs head corners.
      # Leg max_y (debug :max_y = dark green) then matches cap max_y at plank_thickness toward the ledge/slats.
      def foot_corner_leg_y0 = plank_thickness - beam_wide

      # Foot corners moved from the old −beam_y+plank anchor to foot_corner_leg_y0; shift mid-run legs
      # and behind-mid posts headward (−Y) by the same delta.
      def mid_layout_y_shift = beam_y - beam_wide

      # Mid-tie Y anchor on the back frame: one plank_thickness + beam_wide headward of the
      # back-slat footward end (retracted_frame_depth_y), shifted +Y by MID_TIE_OUTWARD_SHIFT so
      # the mid tie sits flush with the outside of the structure. The front extension-stop
      # plank meets it when foot_world_y == usable_length_extended.
      MID_TIE_OUTWARD_SHIFT = 11.mm
      def mid_tie_y0 = retracted_frame_depth_y - plank_thickness - beam_wide + MID_TIE_OUTWARD_SHIFT

      # ── World Y positions for the front frame (sliding half) ──────────────────

      # Front foot at the far end when fully extended.
      def extended_front_foot_world_y = usable_length_extended

      # Upside-down construction row: front half one small-pillow segment past nominal
      # extension (visible comb gap). Upright steps 1–3 use extended_front_foot_world_y.
      def decoupled_front_foot_world_y = usable_length_extended + pillow_small_length

      # Extension-degree previews sit on this row (+Y = head).
      def extension_preview_row_y = 0

      # One row step: bed footprint along Y plus the empty band gap.
      def preview_row_step = usable_length_extended + preview_band_gap

      # Construction-step row — one band below the extension variants.
      def construction_steps_row_y = extension_preview_row_y - preview_row_step

      # Stock cut-plan 3D bars — fourth band, clear of construction row.
      def cut_plan_row_y = construction_steps_row_y - preview_row_step

      # 3rd angle projection layout — fifth band, below cut plan.
      # Extended projection is positioned dynamically below the retracted one
      # (see ThirdAngleProjection.create_scene chaining in BedLayout#create).
      def third_angle_row_y = cut_plan_row_y - preview_row_step

      def preview_column_step = outer_width + pair_gap_x

      # Extra +X for the upside-down step: 180° about +Y mirrors local X, so the
      # group's geometry lies mostly left of its anchor; shift by outer_width so it
      # clears the previous construction column (same row_y).
      def construction_flip_extra_offset_x = outer_width

      # Front foot position when retracted (outer face of front end beam; equals usable_length_retracted).
      def retracted_foot_world_y = usable_length_retracted

      # ── Pillows ───────────────────────────────────────────────────────────────

      # Big pillow matches usable slat bottom; three smalls fill the extension gap (equal thirds).
      # Extended layout on front (foot→head): small | 3, small | 1, small | 2, then big on back.
      def pillow_big_length   = usable_length_retracted
      def small_pillow_count  = 3
      def pillow_small_length = (usable_length_extended - usable_length_retracted) / small_pillow_count.to_f

      # Ext1 preview: retracted + one small flat’s worth of extension.
      def one_small_extension_front_foot_world_y = retracted_foot_world_y + pillow_small_length

      # ── Cap geometry ─────────────────────────────────────────────────────────

      # Head/foot cap: starts at inner face of outer corner leg, spans to the other.
      def cap_x0 = leg_x
      def cap_dx = outer_width - (2 * leg_x)

      # ── SketchUp layer / material names (stable, used across classes) ─────────

      LAYER_NAME          = 'EB_ExtendableBed'
      ATTR_DICT           = 'Timmerman::ExtendableBed'
      PREVIEW_MAT_BACK    = 'EB preview | back'
      PREVIEW_MAT_FRONT   = 'EB preview | front'
      PREVIEW_RGB_BACK    = [188, 152, 106].freeze
      PREVIEW_RGB_OVERLAP = [255, 0, 220].freeze
      STEP_ANNOTATIONS_LAYER = 'EB_Step_Annotations'

      # ── Outliner group names for the four preview pairs ───────────────────────

      GROUP_EXT_BACK     = 'EB_Ext_Back'
      GROUP_EXT_FRONT    = 'EB_Ext_Front'
      GROUP_EXT1_BACK    = 'EB_Ext1_Back'
      GROUP_EXT1_FRONT   = 'EB_Ext1_Front'
      GROUP_RET_BACK     = 'EB_Ret_Back'
      GROUP_RET_FRONT    = 'EB_Ret_Front'
      GROUP_RETGND_BACK  = 'EB_RetGnd_Back'
      GROUP_RETGND_FRONT = 'EB_RetGnd_Front'
      GROUP_CUT_PLAN_3D      = 'EB_CutPlan_3D'
      GROUP_3RD_ANGLE        = 'EB_3rdAngle'
      GROUP_3RD_ANGLE_EXT    = 'EB_3rdAngleExt'

      # Human-readable names for the extension-degree preview row (one label per back+front pair).
      PREVIEW_NAME_EXT1      = 'Extended: 1 pillow'.freeze
      PREVIEW_NAME_EXT       = 'Extended: 3 pillows'.freeze
      PREVIEW_NAME_RET       = 'Retracted: pillows on top'.freeze
      PREVIEW_NAME_RETGND    = 'Retracted: pillows below'.freeze

      EXTENSION_PAIR_DISPLAY_NAME_BY_BACK_ROOT = {
        GROUP_EXT1_BACK   => PREVIEW_NAME_EXT1,
        GROUP_EXT_BACK    => PREVIEW_NAME_EXT,
        GROUP_RET_BACK    => PREVIEW_NAME_RET,
        GROUP_RETGND_BACK => PREVIEW_NAME_RETGND
      }.freeze

      # Construction sequence labels (reversed from original build-order draft):
      # Step 1 = old prep, ... Step 7 = full extended, Step 8 = full retracted (no pillows).
      GROUP_STEP1_BACK = 'EB_Step1_Back'
      GROUP_STEP1_FRONT = 'EB_Step1_Front'
      GROUP_STEP2_BACK = 'EB_Step2_Back'
      GROUP_STEP2_FRONT = 'EB_Step2_Front'
      GROUP_STEP3_BACK = 'EB_Step3_Back'
      GROUP_STEP3_FRONT = 'EB_Step3_Front'
      GROUP_STEP4_BACK = 'EB_Step4_Back'
      GROUP_STEP4_FRONT = 'EB_Step4_Front'
      GROUP_STEP5_BACK = 'EB_Step5_Back'
      GROUP_STEP5_FRONT = 'EB_Step5_Front'
      GROUP_STEP6_BACK = 'EB_Step6_Back'
      GROUP_STEP6_FRONT = 'EB_Step6_Front'
      GROUP_STEP7_BACK = 'EB_Step7_Back'
      GROUP_STEP7_FRONT = 'EB_Step7_Front'
      GROUP_STEP8_BACK = 'EB_Step8_Back'
      GROUP_STEP8_FRONT = 'EB_Step8_Front'

      # Matches any auto-generated EB pair root group name.
      GROUP_NAME_RE = /\AEB_(Ext|Ext1|Ret|RetGnd|Half|Step[1-8]|StepExt|StepDecoup|StepNoLedges|StepFlip|StepFlipNoLegs|StepFlipNoCaps|StepPrep|StepSisterPrep)_(Back|Front)\z/

      # Single-pair root names (cleared together with the multi-pair preview set).
      SINGLE_PAIR_ROOTS = %w[EB_Back EB_Front].freeze

      # Retracted preview pair (non-extended length) — target for native `.glb` export
      # (`GlbExport.export_nonextended_pair`). See skill `export-nonextended-bed-glb`.
      NONEXTENDED_GLB_EXPORT_ROOTS = [GROUP_RET_BACK, GROUP_RET_FRONT].freeze

      # Written on each successful BedLayout#create (named-group geometry snapshot).
      GEOMETRY_BASELINE_JSON =
        File.expand_path('../references/extendable_bed_geometry_baseline.json', __dir__).freeze

      # Design-reference copies placed manually in the model — cleared must NOT touch these.
      REFERENCE_ROOT_RE = /\A(?:NEW|New)_EB_Ext_(Back|Front)\z/

      # ── Part-name prefixes and regexes ───────────────────────────────────────

      PLANK_NAME_RE  = /\AEB \| plank \|/
      PILLOW_NAME_RE = /\AEB \| pillow \|/
      # Sibling hardware groups under each frame root (cleared with parent).
      SCREW_NAME_RE  = /\AEB \| screw \|/
      # Structural parts checked by the AABB overlap validator (excludes screws, pillows, helpers).
      SOLID_NAME_RE  = /\AEB \| (beam|leg|slat|plank) \|/

      # Nested part-group names to erase on clear (previous labels after part renames).
      # Each entry is an exact Outliner group name; both are cleared before re-rendering.
      PURGE_NESTED_PART_GROUP_NAMES = [
        'EB | beam | behind leg | mid -X',
        'EB | beam | behind leg | mid +X',
        'EB | beam | behind leg | head -X',
        'EB | beam | behind leg | head +X',
        'EB | beam | behind leg | mid -X | headward',
        'EB | beam | behind leg | mid +X | headward',
        'EB | beam | mid tie | vertical filler | -X',
        'EB | beam | mid tie | vertical filler | +X',
        # Renamed in the PartCatalog refactor; list old names so old renders clear cleanly.
        'EB | beam | sister | outer -X',
        'EB | beam | sister | outer +X',
        'EB | beam | mid tie | between sisters',
        'EB | leg | post | behind mid | -X | headward',
        'EB | leg | post | behind mid | +X | headward',
        'EB | beam | front | under slats | foot end',
        'EB | beam | front | under slat foot'
      ].freeze
    end
  end
end
