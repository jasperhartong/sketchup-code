# frozen_string_literal: true
# LayOut sheet set: retracted bed + pillows (side / front / top) with key dimensions.

sketchup_bridge_dir = File.dirname(__dir__)
repo_root = File.expand_path('..', sketchup_bridge_dir)

require 'pathname' unless defined?(Pathname)
require 'fileutils' unless defined?(FileUtils)

load File.expand_path('scripts/extendable-bed/extendable-bed.rb', repo_root)
load File.expand_path('scripts/extendable-bed/lib/retracted_pillow_layout_export.rb', repo_root)

puts '[EB layout] starting export...'

layout_out = ENV['EB_LAYOUT_PATH']
if layout_out
  pn = Pathname.new(layout_out)
  layout_out = pn.absolute? ? pn.expand_path.to_s : File.expand_path(layout_out, repo_root)
end

pdf_out = ENV['EB_LAYOUT_PDF'] == '0' ? false : nil

unless defined?(Layout::Document)
  puts '[EB layout] ERROR: LayOut Ruby API not available (SketchUp Pro with LayOut required).'
  @eb_layout_result = 'FAIL'
else
  begin
    result = Timmerman::ExtendableBed::RetractedPillowLayoutExport.export(
      model: Sketchup.active_model,
      config: Timmerman::ExtendableBed::Config.new,
      layout_path: layout_out,
      pdf_path: pdf_out
    )

    puts '[EB layout] pages: ' + result[:pages].join(', ')
    puts "[EB layout] SketchUp model: #{result[:skp_path]}"
    puts "[EB layout] LayOut document: #{result[:layout_path]}"
    puts "[EB layout] PDF: #{result[:pdf_path]}" if result[:pdf_path]
    @eb_layout_result = 'OK'
  rescue StandardError => e
    puts "[EB layout] ERROR: #{e.class}: #{e.message}"
    e.backtrace.first(8).each { |line| puts "  #{line}" }
    @eb_layout_result = 'FAIL'
  end
end

@eb_layout_result
