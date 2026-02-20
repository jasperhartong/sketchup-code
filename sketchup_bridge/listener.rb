# SketchUp Bridge — standalone listener (no plugin required)
#
# Load once in the Ruby Console (Window → Ruby Console):
#   load '/Users/jasper/Timmerman/sketchup-code/sketchup_bridge/listener.rb'
#
# Preferred alternative: install the bridge plugin and use
#   Extensions → SketchUp Bridge → Start Listener

load File.expand_path('../plugins/timmerman_sketchup_bridge/core.rb', __dir__)

Timmerman::SketchupBridge.stop if Timmerman::SketchupBridge.running?
Timmerman::SketchupBridge.bridge_dir = __dir__
Timmerman::SketchupBridge.start
