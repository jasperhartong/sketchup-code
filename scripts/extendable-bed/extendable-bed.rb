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

_eb_lib = File.expand_path('lib', __dir__)

%w[
  config
  parts
  renderer
  stock_planner
  validator
  frame_assembly
  bed_pair
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
