#!/usr/bin/env ruby
# Run from Cursor/agent: after writing sketchup_bridge/command.rb, run:
#   ruby sketchup_bridge/run_and_wait.rb
# Waits for SketchUp to execute command.rb, then prints result.txt.

bridge_dir = File.expand_path(File.dirname(__FILE__))
result_file = File.join(bridge_dir, 'result.txt')
command_file = File.join(bridge_dir, 'command.rb')

unless File.exist?(command_file)
  puts "ERROR: command.rb not found. Write code to sketchup_bridge/command.rb first."
  exit 1
end

# Give SketchUp time to notice the change (listener polls every 2s)
# Wait until result.txt is at least as new as command.rb
cmd_mtime = File.mtime(command_file)
max_wait = 15
elapsed = 0
step = 0.5

while elapsed < max_wait
  sleep(step)
  elapsed += step
  next unless File.exist?(result_file)
  break if File.mtime(result_file) >= cmd_mtime
end

if File.exist?(result_file) && File.mtime(result_file) >= cmd_mtime
  puts File.read(result_file)
else
  puts "TIMEOUT: SketchUp did not run command.rb in #{max_wait}s. Is the listener loaded? (load 'sketchup_bridge/listener.rb' in Ruby Console)"
  exit 1
end
