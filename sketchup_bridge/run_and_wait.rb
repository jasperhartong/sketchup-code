#!/usr/bin/env ruby
require 'fileutils'
# Run from Cursor/agent: after writing sketchup_bridge/command.rb, run:
#   ruby sketchup_bridge/run_and_wait.rb
# Waits for SketchUp to execute command.rb, then prints result.txt.
# If the bridge is not connected (listener not running in SketchUp), this script
# fails and reports that clearly so the user knows to start the listener.

bridge_dir = File.expand_path(File.dirname(__FILE__))
result_file = File.join(bridge_dir, 'result.txt')
command_file = File.join(bridge_dir, 'command.rb')

unless File.exist?(command_file)
  puts "ERROR: command.rb not found. Write code to sketchup_bridge/command.rb first."
  exit 1
end

# Touch command.rb so the listener will run it (it runs when command.rb is newer than last run).
# Then we only accept result.txt written after this moment — so we never use stale output
# when the listener isn't running.
FileUtils.touch(command_file)
cmd_mtime = File.mtime(command_file)
max_wait = 15
elapsed = 0
step = 0.25  # catch result soon after SketchUp writes (SketchUp polls every 2s)

while elapsed < max_wait
  sleep(step)
  elapsed += step
  next unless File.exist?(result_file)
  break if File.mtime(result_file) >= cmd_mtime
end

if File.exist?(result_file) && File.mtime(result_file) >= cmd_mtime
  puts File.read(result_file, encoding: 'UTF-8')
  exit 0
end

puts ""
puts "=== BRIDGE NOT CONNECTED ==="
puts "SketchUp did not run the command within #{max_wait} seconds."
puts ""
puts "The bridge only works when the listener is running inside SketchUp."
puts "  • Start SketchUp, then start the bridge listener:"
puts "    Extensions → SketchUp Bridge → Start Listener"
puts "    (or load the listener from the Ruby Console)."
puts "  • Set the bridge directory to this project's sketchup_bridge/ folder if prompted."
puts ""
puts "Then run this script again."
puts "=== BRIDGE NOT CONNECTED ==="
puts ""
exit 1
