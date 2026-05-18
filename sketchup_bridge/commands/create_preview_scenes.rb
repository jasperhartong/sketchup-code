# frozen_string_literal: true
# SketchUp Scene tabs: variants iso, construction iso, cut plan top, Ret ortho views.

sketchup_bridge_dir = File.dirname(__dir__)
repo_root = File.expand_path('..', sketchup_bridge_dir)

load File.expand_path('scripts/extendable-bed/extendable-bed.rb', repo_root)
load File.expand_path('scripts/extendable-bed/lib/preview_scenes.rb', repo_root)

Timmerman::ExtendableBed::PreviewScenes.create_standard_set

'OK'
