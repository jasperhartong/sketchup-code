#!/usr/bin/env bash
# Build .rbz packages for all (or a named) plugin.
#
# Usage:
#   ./package.sh                   # build all plugins
#   ./package.sh skeleton          # build only timmerman_skeleton_dimensions
#   ./package.sh bridge            # build only timmerman_sketchup_bridge

set -euo pipefail

PLUGIN_SRC="$(dirname "$0")/plugins"
DIST="$(dirname "$0")/dist"
mkdir -p "$DIST"

build() {
  local id="$1"
  local loader="$PLUGIN_SRC/$id.rb"
  local version
  version=$(grep 'EXTENSION\.version' "$loader" | grep -o "['\"][^'\"]*['\"]" | tr -d "'\"")
  local out
  out="$(cd "$DIST" && pwd)/${id}-${version}.rbz"

  local tmp
  tmp=$(mktemp -d)
  cp "$loader" "$tmp/"
  cp -r "$PLUGIN_SRC/$id" "$tmp/"
  (cd "$tmp" && zip -qr "$out" "${id}.rb" "$id")
  rm -rf "$tmp"

  echo "  ✓ ${id}-${version}.rbz ($(du -sh "$out" | cut -f1))"
}

FILTER="${1:-}"
PLUGINS=(timmerman_skeleton_dimensions timmerman_sketchup_bridge)

for id in "${PLUGINS[@]}"; do
  [[ -z "$FILTER" || "$id" == *"$FILTER"* ]] && build "$id"
done
