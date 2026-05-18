# frozen_string_literal: true

# Extendable interlocking-slats bed.
#
# Coordinates: +Y head → foot (extension). +Z up. Slats run parallel to Y.
# SketchUp stores lengths internally as inches; all literals use .mm.
#
# Load this file in SketchUp's Ruby Console or via the bridge:
#   load '/path/to/extendable-bed.rb'
#
# Then:
#   Timmerman::ExtendableBed::BedLayout.new.create    # build all preview pairs
#   Timmerman::ExtendableBed::BedLayout.new.clear     # erase all EB groups
#   Timmerman::ExtendableBed::BedLayout.new.validate  # AABB overlap (beams/legs/slats/planks per preview pair)
#
# Native GLB (retracted pair only): load lib/export_nonextended_bed_glb.rb, then
#   Timmerman::ExtendableBed::GlbExport.export_nonextended_pair('/path/out.glb')
# Bridge: sketchup_bridge/commands/export_nonextended_bed_glb.rb — skill: export-nonextended-bed-glb.
#
# LayOut sheets (retracted + pillows, side/front/top + key dims): load
#   lib/retracted_pillow_layout_export.rb, then RetractedPillowLayoutExport.export
# Bridge: sketchup_bridge/commands/export_retracted_pillow_layout.rb
#
# SketchUp Scene tabs (variants, construction steps, cut plan) — created during BedLayout#create.
# Standalone refresh: sketchup_bridge/commands/create_preview_scenes.rb
#
# To customise dimensions, pass a Config to BedLayout:
#   config = Timmerman::ExtendableBed::Config.new(back_slat_count: 11, usable_length_extended: 2200.mm, usable_length_retracted: 1300.mm)
#   Timmerman::ExtendableBed::BedLayout.new(config).create
#
# Hardware / debug (optional Config keyword args):
#   debug_color: :off | :sides | :components_reuse | :overlaps
#     :sides            — six colours on axis-aligned part faces
#     :components_reuse — same color for all instances sharing a component definition.
#   show_cut_plan_3d: true|false — render stock bars and assigned cuts as 3D geometry.
#   hardware_cut_hosts: true  — cut countersink + hole in wood (experimental; default false
#                               because add_circle/add_face on thin planks can invalidate
#                               the host group in SketchUp 2026 — use Face#split or manual
#                               workflow until stabilized).
#   hardware_countersink_first: true — pocket then through hole; false — single clearance bore.
#   hardware_through_hole: false — skip the through step when countersink_first is true.

_eb_lib    = File.expand_path('lib', __dir__)
_su_utils  = File.expand_path('../sketchup_utils', __dir__)

# Generic, bed-agnostic part-modelling utilities (Parts, Hardware, PartCatalog,
# Transform, PocketGeometry, Renderer interface + SketchUp impl, PartRendering).
%w[
  parts
  hardware
  transform
  pocket_geometry
  renderer
  scene_capture
  sketchup_renderer
  part_catalog
  part_rendering
].each { |f| load File.join(_su_utils, "#{f}.rb") }

# Extendable-bed-specific code.
%w[
  config
  bed_part_groups
  stock_planner
  validator
  frame_assembly
  pillow_sets
  bed_pair
  construction_steps
  bed_layout
  dimensions
  retracted_pillow_layout_export
  preview_scenes
  third_angle_projection
].each { |f| load File.join(_eb_lib, "#{f}.rb") }

module Timmerman
  module ExtendableBed
    module_function

    def create(model = Sketchup.active_model)
      BedLayout.new.create(model)
    end

    def clear(model = Sketchup.active_model)
      BedLayout.new.clear(model)
    end

    def validate(model = Sketchup.active_model)
      BedLayout.new.validate(model)
    end
  end
end
