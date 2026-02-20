# timmerman_skeleton_dimensions.rb
#
# SketchUp extension loader.
# Install by placing this file and the timmerman_skeleton_dimensions/ folder
# both inside your SketchUp Plugins directory, or install via the .rbz package.

require 'sketchup.rb'
require 'extensions.rb'

module Timmerman
  module SkeletonDimensions
    PLUGIN_ID   = 'timmerman_skeleton_dimensions'.freeze
    PLUGIN_ROOT = File.join(File.dirname(__FILE__), PLUGIN_ID).freeze

    EXTENSION = SketchupExtension.new(
      'Skeleton Dimensions',
      File.join(PLUGIN_ROOT, 'main')
    )

    EXTENSION.version     = '1.0.0'
    EXTENSION.creator     = 'Timmerman'
    EXTENSION.copyright   = '© 2026 Timmerman'
    EXTENSION.description =
      'Adds cumulative, per-beam, and diagonal dimensions to wooden ' \
      'skeleton structures. Select one component instance, then use ' \
      'Extensions > Skeleton Dimensions > Add Dimensions.'

    Sketchup.register_extension(EXTENSION, true)
  end
end
