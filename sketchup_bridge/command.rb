core = File.expand_path('../plugins/timmerman_skeleton_dimensions/core.rb', __dir__)
load core
Timmerman::SkeletonDimensions.debug_mode = true
Timmerman::SkeletonDimensions.clear
Timmerman::SkeletonDimensions.run

"OK"
