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
#   Timmerman::ExtendableBed::BedLayout.new.validate  # AABB overlap check
#
# To customise dimensions, pass a Config to BedLayout:
#   config = Timmerman::ExtendableBed::Config.new(back_slat_count: 11, length_extended: 2200.mm)
#   Timmerman::ExtendableBed::BedLayout.new(config).create
#
# Hardware / debug (optional Config keyword args):
#   debug_paint_faces: true     — six colours on axis-aligned part faces (after highlights).
#   hardware_cut_hosts: true  — cut countersink + hole in wood (experimental; default false
#                               because add_circle/add_face on thin planks can invalidate
#                               the host group in SketchUp 2026 — use Face#split or manual
#                               workflow until stabilized).
#   hardware_countersink_first: true — pocket then through hole; false — single clearance bore.
#   hardware_through_hole: false — skip the through step when countersink_first is true.

_eb_lib = File.expand_path('lib', __dir__)

%w[
  screw_placement
  config
  parts
  renderer
  stock_planner
  validator
  frame_assembly
  bed_pair
  construction_steps
  bed_layout
  dimensions
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
