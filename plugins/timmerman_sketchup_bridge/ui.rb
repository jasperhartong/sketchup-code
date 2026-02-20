# ui.rb — menus for the SketchUp Bridge plugin
#
# Loaded automatically at the end of main.rb once the module methods are defined.

require 'sketchup.rb'

module Timmerman
  module SketchupBridge

    unless file_loaded?(__FILE__)

      # ------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------

      cmd_start = UI::Command.new('Start Listener') {
        Timmerman::SketchupBridge.start
      }
      cmd_start.tooltip        = 'Start polling command.rb in the bridge directory'
      cmd_start.status_bar_text = 'Starts the file-based bridge listener (polls every 2 s).'
      cmd_start.set_validation_proc {
        Timmerman::SketchupBridge.running? ? MF_GRAYED : MF_ENABLED
      }

      cmd_stop = UI::Command.new('Stop Listener') {
        Timmerman::SketchupBridge.stop
      }
      cmd_stop.tooltip         = 'Stop the bridge listener'
      cmd_stop.status_bar_text = 'Stops the file-based bridge listener.'
      cmd_stop.set_validation_proc {
        Timmerman::SketchupBridge.running? ? MF_ENABLED : MF_GRAYED
      }

      cmd_dir = UI::Command.new('Set Bridge Directory…') {
        current = Timmerman::SketchupBridge.bridge_dir
        chosen  = UI.select_directory(
          title:     'Select Bridge Directory',
          directory: File.exist?(current) ? current : File.expand_path('~')
        )
        next unless chosen
        was_running = Timmerman::SketchupBridge.running?
        Timmerman::SketchupBridge.stop if was_running
        Timmerman::SketchupBridge.bridge_dir = chosen
        puts "[SketchUp Bridge] Bridge dir → #{chosen}"
        Timmerman::SketchupBridge.start if was_running
      }
      cmd_dir.tooltip         = 'Choose the folder containing command.rb / result.txt'
      cmd_dir.status_bar_text = 'Point the bridge at your project\'s sketchup_bridge/ folder.'

      cmd_status = UI::Command.new('Show Status') {
        dir    = Timmerman::SketchupBridge.bridge_dir
        state  = Timmerman::SketchupBridge.running? ? 'RUNNING' : 'STOPPED'
        UI.messagebox("SketchUp Bridge status: #{state}\nBridge dir: #{dir}")
      }
      cmd_status.tooltip = 'Show bridge status and current directory'

      # ------------------------------------------------------------------
      # Menu: Extensions > SketchUp Bridge
      # ------------------------------------------------------------------

      menu = UI.menu('Extensions').add_submenu('SketchUp Bridge')
      menu.add_item(cmd_start)
      menu.add_item(cmd_stop)
      menu.add_separator
      menu.add_item(cmd_dir)
      menu.add_item(cmd_status)

      file_loaded(__FILE__)
    end

  end
end
