# ui.rb — menus and toolbar for Skeleton Dimensions
#
# Loaded automatically at the end of main.rb once the module methods are defined.

require 'sketchup.rb'

module Timmerman
  module SkeletonDimensions

    unless file_loaded?(__FILE__)

      # ------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------

      cmd_run = UI::Command.new('Add Dimensions') {
        Timmerman::SkeletonDimensions.run
      }
      cmd_run.tooltip      = 'Add cumulative, per-beam, and diagonal dimensions'
      cmd_run.status_bar_text = 'Select one component instance, then click to add dimensions.'
      cmd_run.small_icon   = File.join(PLUGIN_ROOT, 'icons', 'run_16.png')  if File.exist?(File.join(PLUGIN_ROOT, 'icons', 'run_16.png'))
      cmd_run.large_icon   = File.join(PLUGIN_ROOT, 'icons', 'run_24.png')  if File.exist?(File.join(PLUGIN_ROOT, 'icons', 'run_24.png'))

      cmd_clear = UI::Command.new('Clear Dimensions') {
        Timmerman::SkeletonDimensions.clear
      }
      cmd_clear.tooltip       = 'Remove all linear dimensions from the model'
      cmd_clear.status_bar_text = 'Select one component instance, then click to clear its dimensions.'
      cmd_clear.small_icon    = File.join(PLUGIN_ROOT, 'icons', 'clear_16.png') if File.exist?(File.join(PLUGIN_ROOT, 'icons', 'clear_16.png'))
      cmd_clear.large_icon    = File.join(PLUGIN_ROOT, 'icons', 'clear_24.png') if File.exist?(File.join(PLUGIN_ROOT, 'icons', 'clear_24.png'))

      # ------------------------------------------------------------------
      # Menu: Extensions > Skeleton Dimensions
      # ------------------------------------------------------------------

      menu = UI.menu('Extensions').add_submenu('Skeleton Dimensions')
      menu.add_item(cmd_run)
      menu.add_item(cmd_clear)

      file_loaded(__FILE__)
    end

  end
end
