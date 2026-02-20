# SketchUp Bridge Listener
# Load this once in SketchUp (Window → Ruby Console):
#   load '<project>/sketchup_bridge/listener.rb'
#
# Then the agent can write code to command.rb; this script runs it every 2s
# when command.rb changes and writes stdout/stderr to result.txt.

BRIDGE_DIR = File.expand_path(File.dirname(__FILE__))
COMMAND_FILE = File.join(BRIDGE_DIR, 'command.rb')
RESULT_FILE  = File.join(BRIDGE_DIR, 'result.txt')
LAST_RUN_FILE = File.join(BRIDGE_DIR, '.last_run')

@bridge_last_mtime = 0

def run_bridge_command
  return unless File.exist?(COMMAND_FILE)
  mtime = File.mtime(COMMAND_FILE).to_f
  return if mtime <= @bridge_last_mtime

  @bridge_last_mtime = mtime
  code = File.read(COMMAND_FILE)
  out = StringIO.new
  err = StringIO.new
  old_stdout = $stdout
  old_stderr = $stderr
  $stdout = out
  $stderr = err
  result = nil
  begin
    result = eval(code, TOPLEVEL_BINDING, COMMAND_FILE)
    out.puts("\n=> #{result.inspect}") unless result.nil?
  rescue => e
    err.puts("#{e.class}: #{e.message}")
    e.backtrace.first(20).each { |l| err.puts("  #{l}") }
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  File.write(RESULT_FILE, "=== stdout ===\n#{out.string}\n=== stderr ===\n#{err.string}")
  File.write(LAST_RUN_FILE, mtime.to_s)
end

# Poll every 2 seconds
@bridge_timer = UI.start_timer(2, true) { run_bridge_command }
puts "[SketchUp Bridge] Listening. Command file: #{COMMAND_FILE}"
