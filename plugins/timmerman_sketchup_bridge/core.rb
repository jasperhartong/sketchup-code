# core.rb — SketchUp Bridge listener logic
#
# Single source of truth for the polling logic. Used in two ways:
#
#   Plugin:      main.rb does `load core.rb` then `require ui.rb`
#   Standalone:  listener.rb does `load core.rb` then sets bridge_dir + calls start
#
# Public API:
#   Timmerman::SketchupBridge.start            — start polling
#   Timmerman::SketchupBridge.stop             — stop polling
#   Timmerman::SketchupBridge.running?         — true while the timer is active
#   Timmerman::SketchupBridge.bridge_dir       — current bridge directory path
#   Timmerman::SketchupBridge.bridge_dir=      — set + persist bridge directory

require 'sketchup.rb'
require 'fileutils'
require 'stringio'

module Timmerman
  module SketchupBridge
    extend self

    # Reload guard — remove constants before redefining so re-loading this file
    # always picks up the latest values.
    %i[PREFS_KEY PREFS_DIR_KEY POLL_INTERVAL
       DEFAULT_BRIDGE_DIR RDEBUG_LAUNCH_CMD].each do |c|
      remove_const(c) if const_defined?(c, false)
    end

    PREFS_KEY      = 'TimmermanSketchupBridge'.freeze
    PREFS_DIR_KEY  = 'bridge_dir'.freeze
    POLL_INTERVAL  = 2  # seconds

    # Default bridge directory — used until the user points it at a project.
    DEFAULT_BRIDGE_DIR = File.join(File.expand_path('~'), 'sketchup_bridge').freeze

    # Adjust app name/path if your SketchUp version differs (e.g. SketchUp 2025).
    RDEBUG_LAUNCH_CMD =
      'open -a /Applications/SketchUp\ 2026/SketchUp.app --args -rdebug "ide port=6123"'.freeze

    # ---------------------------------------------------------------------------
    # Configuration
    # ---------------------------------------------------------------------------

    def bridge_dir
      saved = Sketchup.read_default(PREFS_KEY, PREFS_DIR_KEY, '')
      saved.to_s.strip.empty? ? DEFAULT_BRIDGE_DIR : saved
    end

    def bridge_dir=(path)
      Sketchup.write_default(PREFS_KEY, PREFS_DIR_KEY, path)
    end

    # ---------------------------------------------------------------------------
    # AppObserver — stops the timer cleanly when SketchUp quits
    # ---------------------------------------------------------------------------

    class BridgeAppObserver < Sketchup::AppObserver
      def onQuit
        Timmerman::SketchupBridge.stop if Timmerman::SketchupBridge.running?
      end
    end

    # ---------------------------------------------------------------------------
    # Listener lifecycle
    # ---------------------------------------------------------------------------

    def running?
      !@bridge_timer.nil?
    end

    def register_quit_observer
      return if @app_observer
      @app_observer = BridgeAppObserver.new
      Sketchup.add_observer(@app_observer)
    end

    def start
      if running?
        puts "[SketchUp Bridge] Already running (bridge dir: #{bridge_dir})"
        return
      end

      dir = bridge_dir
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

      command_file = File.join(dir, 'command.rb')
      results_dir  = File.join(dir, 'results')
      FileUtils.mkdir_p(results_dir) unless Dir.exist?(results_dir)
      result_file  = File.join(results_dir, 'result.txt')

      @bridge_last_mtime = 0

      @bridge_timer = UI.start_timer(POLL_INTERVAL, true) {
        next unless File.exist?(command_file)

        mtime = File.mtime(command_file).to_f
        next if mtime <= @bridge_last_mtime

        @bridge_last_mtime = mtime
        run_command(File.read(command_file), command_file, result_file)
      }

      puts "[SketchUp Bridge] Listening. Bridge dir: #{dir}"
      puts "[SketchUp Bridge] For IDE debugging, start SketchUp with:"
      puts "  #{RDEBUG_LAUNCH_CMD}"
    end

    def stop
      unless running?
        puts "[SketchUp Bridge] Not running."
        return
      end
      UI.stop_timer(@bridge_timer)
      @bridge_timer = nil
      puts "[SketchUp Bridge] Stopped."
    end

    # ---------------------------------------------------------------------------
    # Command execution
    # ---------------------------------------------------------------------------

    def run_command(code, command_file, result_file)
      out = StringIO.new
      err = StringIO.new
      old_out, old_err = $stdout, $stderr
      $stdout, $stderr = out, err

      result = nil
      begin
        result = eval(code, TOPLEVEL_BINDING, command_file)
        out.puts("\n=> #{result.inspect}") unless result.nil?
      rescue StandardError => e
        err.puts("#{e.class}: #{e.message}")
        e.backtrace.first(20).each { |l| err.puts("  #{l}") }
        err.puts("\nTip: for IDE debugging, restart SketchUp with:")
        err.puts("  #{RDEBUG_LAUNCH_CMD}")
      rescue Exception => e
        # Fatal (e.g. NoMemoryError, SignalException) — still write result so agent sees something
        err.puts("Fatal: #{e.class}: #{e.message}")
        e.backtrace&.first(20)&.each { |l| err.puts("  #{l}") }
      ensure
        $stdout, $stderr = old_out, old_err
      end

      File.write(result_file, "=== stdout ===\n#{out.string}\n=== stderr ===\n#{err.string}")
    end

    # Register once when the plugin loads — safe to call on every `load` because
    # register_quit_observer guards against double-registration with @app_observer.
    register_quit_observer

  end
end
