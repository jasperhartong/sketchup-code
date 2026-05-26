# frozen_string_literal: true

# Deprecated: geometry snapshot/diff lives in the shared util. Loading this file
# pulls it in for old bookmarks.
#
#   Timmerman::SketchupUtils::NamedGroupGeometrySnapshot
#
# Baseline JSON after each BedLayout#create:
#   Timmerman::ExtendableBed::Config::GEOMETRY_BASELINE_JSON

load File.expand_path('../sketchup_utils/named_group_geometry_snapshot.rb', __dir__)
