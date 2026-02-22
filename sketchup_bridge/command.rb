core = File.expand_path('../plugins/timmerman_skeleton_dimensions/core.rb', __dir__)
load core
Timmerman::SkeletonDimensions.debug_mode = true
Timmerman::SkeletonDimensions.clear
Timmerman::SkeletonDimensions.run

# Diagnostic: list all tag layers and check for dimension tag
model = Sketchup.active_model
puts "[Tags] Total layers: #{model.layers.size}"
model.layers.each { |l| vis = l.respond_to?(:visible?) ? l.visible? : (l.visible if l.respond_to?(:visible)); puts "  - #{l.name.inspect} visible=#{vis.inspect}" }
if model.layers.respond_to?(:folders)
  puts "[Tags] Folders:"
  model.layers.folders.each { |f| puts "  folder: #{f.name}" }
end
maten_layers = model.layers.to_a.select { |l| l.name.to_s.start_with?('maten') }
puts "[Tags] Layers starting with 'maten': #{maten_layers.map(&:name).inspect}"

"OK"
