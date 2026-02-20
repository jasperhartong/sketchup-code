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

      cmd_port = UI::Command.new('Set Debug Port…') {
        current = Timmerman::SketchupBridge.debug_port.to_s
        result  = UI.inputbox(['Debug port:'], [current], 'Set Ruby Debug Port')
        next unless result
        port = result[0].to_i
        next if port <= 0
        Timmerman::SketchupBridge.debug_port = port
        puts "[SketchUp Bridge] Debug port → #{port}"
      }
      cmd_port.tooltip = 'Set the port used to detect the Ruby debug IDE connection'

      cmd_status = UI::Command.new('Show Status') {
        dir   = Timmerman::SketchupBridge.bridge_dir
        port  = Timmerman::SketchupBridge.debug_port
        state = Timmerman::SketchupBridge.running? ? 'RUNNING' : 'STOPPED'
        debug = Timmerman::SketchupBridge.debug_port_open? ? "open (port #{port})" : "closed (port #{port})"
        UI.messagebox("SketchUp Bridge status: #{state}\nBridge dir: #{dir}\nDebug port: #{debug}")
      }
      cmd_status.tooltip = 'Show bridge status, directory, and debug port'

      # ------------------------------------------------------------------
      # Menu: Extensions > SketchUp Bridge
      # ------------------------------------------------------------------

      menu = UI.menu('Extensions').add_submenu('SketchUp Bridge')
      menu.add_item(cmd_start)
      menu.add_item(cmd_stop)
      menu.add_separator
      menu.add_item(cmd_dir)
      menu.add_item(cmd_port)
      menu.add_item(cmd_status)

      file_loaded(__FILE__)
    end

  end
end
