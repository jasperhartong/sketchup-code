# frozen_string_literal: true

load File.expand_path('../../scripts/extendable-bed/extendable-bed.rb', __dir__)

config = Timmerman::ExtendableBed::Config.new(debug_color: :off)
layout = Timmerman::ExtendableBed::BedLayout.new(config)
layout.clear
layout.create

model = Sketchup.active_model
defs = model.definitions.select { |d| d.valid? && d.name.start_with?('EB::') }
insts = model.entities.grep(Sketchup::Group).sum do |root|
  root.definition.entities # touch for consistency
  root.entities.select { |e| e.is_a?(Sketchup::ComponentInstance) && e.valid? }.length
end

puts "[component-migration] EB definitions: #{defs.length}"
puts "[component-migration] top-level child component instances under EB roots: #{insts}"

cfg = Timmerman::ExtendableBed::Config
step_roots = model.entities.grep(Sketchup::Group).select { |g| g.valid? && g.name =~ /\AEB_Step[1-7]_(Back|Front)\z/ }
puts "[component-migration] step roots: #{step_roots.length} (expected 14)"

missing_visibility_targets = []
layout.pairs_for(Timmerman::ExtendableBed::BackFrame.new(config), Timmerman::ExtendableBed::FrontFrame.new(config)).each do |pair|
  [pair.back_name, pair.back_hidden_part_names, pair.back_highlight_part_names].tap do |root_name, hidden_names, highlight_names|
    root = model.entities.grep(Sketchup::Group).find { |g| g.name == root_name }
    next unless root
    children = root.entities.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
    names = children.map(&:name)
    (Array(hidden_names) + Array(highlight_names)).each do |name|
      missing_visibility_targets << "#{root_name}:#{name}" unless names.include?(name)
    end
  end

  [pair.front_name, pair.front_hidden_part_names, pair.front_highlight_part_names].tap do |root_name, hidden_names, highlight_names|
    root = model.entities.grep(Sketchup::Group).find { |g| g.name == root_name }
    next unless root
    children = root.entities.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
    names = children.map(&:name)
    (Array(hidden_names) + Array(highlight_names)).each do |name|
      missing_visibility_targets << "#{root_name}:#{name}" unless names.include?(name)
    end
  end
end

if missing_visibility_targets.empty?
  puts '[component-migration] PASS visibility targets resolved by name'
else
  puts "[component-migration] FAIL visibility target misses: #{missing_visibility_targets.length}"
  missing_visibility_targets.first(20).each { |msg| puts "  #{msg}" }
end

baseline_path = cfg::GEOMETRY_BASELINE_JSON
puts "[component-migration] baseline exists: #{File.exist?(baseline_path)}"

'OK'
