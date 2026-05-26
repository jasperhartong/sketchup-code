#!/usr/bin/env ruby
require 'fileutils'
# Run from Cursor/agent:
#   ruby sketchup_bridge/run_and_wait.rb
#
# Touches command.rb on purpose: the listener only re-executes when that file's mtime
# advances (saving an edit also works; touch covers re-runs without a content change).
# Then waits for results/result.txt from this run so you never read stale output.
# Fails with BRIDGE NOT CONNECTED if SketchUp does not respond.
#
# command.rb must already say what you want (default rebuild, or a temporary capture load — see comment in command.rb).

bridge_dir = File.expand_path(File.dirname(__FILE__))
results_dir = File.join(bridge_dir, 'results')
FileUtils.mkdir_p(results_dir)
result_file = File.join(results_dir, 'result.txt')
command_file = File.join(bridge_dir, 'command.rb')

unless File.exist?(command_file)
  puts "ERROR: command.rb not found under #{bridge_dir}"
  exit 1
end

# Trigger listener + align result.txt mtime with this invocation.
FileUtils.touch(command_file)
cmd_mtime = File.mtime(command_file)
max_wait = (ENV['SKETCHUP_BRIDGE_MAX_WAIT'] || '15').to_f
elapsed = 0
step = 0.25 # catch result soon after SketchUp writes (SketchUp polls every 2s)

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
