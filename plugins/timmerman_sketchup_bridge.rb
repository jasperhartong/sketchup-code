# timmerman_sketchup_bridge.rb
#
# SketchUp extension loader for the agent development bridge.
# Provides a menu to start/stop the file-based command listener used by
# the Cursor agent — no more manual `load` in the Ruby Console.
#
# Install via the .rbz package or by dropping this file and the
# timmerman_sketchup_bridge/ folder into your SketchUp Plugins directory.

require 'sketchup.rb'
require 'extensions.rb'

module Timmerman
  module SketchupBridge
    PLUGIN_ID   = 'timmerman_sketchup_bridge'.freeze
    PLUGIN_ROOT = File.join(File.dirname(__FILE__), PLUGIN_ID).freeze

    EXTENSION = SketchupExtension.new(
      'SketchUp Bridge',
      File.join(PLUGIN_ROOT, 'main')
    )

    EXTENSION.version     = '1.5.1'
    EXTENSION.creator     = 'Timmerman'
    EXTENSION.copyright   = '© 2026 Timmerman'
    EXTENSION.description =
      'File-based command bridge for agent-driven development. ' \
      'Polls a command.rb file and writes results to result.txt, ' \
      'letting external tools (e.g. Cursor) run code inside SketchUp.'

    Sketchup.register_extension(EXTENSION, true)
  end
end
