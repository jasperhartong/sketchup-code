# frozen_string_literal: true
# Writes native `.glb` for the retracted (non-extended) preview pair only.
# Requires SketchUp 2024+ for Model#export → .glb.
#
# From command.rb:
#   load File.expand_path('commands/export_nonextended_bed_glb.rb', __dir__)
#
# Optional: ENV['EB_GLB_PATH'] = absolute or repo-relative output path.

sketchup_bridge_dir = File.dirname(__dir__)
repo_root = File.expand_path('..', sketchup_bridge_dir)

require 'pathname' unless defined?(Pathname)

load File.expand_path('scripts/extendable-bed/extendable-bed.rb', repo_root)
load File.expand_path('scripts/extendable-bed/lib/export_nonextended_bed_glb.rb', repo_root)

out = ENV['EB_GLB_PATH']
if out
  pn = Pathname.new(out)
  out = pn.absolute? ? pn.expand_path.to_s : File.expand_path(out, repo_root)
else
  out = File.expand_path('sketchup_bridge/results/extendable_bed_nonextended.glb', repo_root)
end

require 'fileutils' unless defined?(FileUtils)
FileUtils.mkdir_p(File.dirname(out))

ok = Timmerman::ExtendableBed::GlbExport.export_nonextended_pair(out, Sketchup.active_model)
if ok && File.file?(out)
  puts "Wrote #{out} (#{File.size(out)} bytes)"
else
  puts "Export failed or file missing (Model#export => #{ok.inspect}). Need SketchUp 2024+ and .glb support."
end

'OK'
