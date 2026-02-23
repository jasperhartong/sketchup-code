---
name: package-plugin
description: Package a SketchUp Ruby plugin into a .rbz file. Use when the user asks to package, build, release, or distribute a plugin. ALWAYS bump the version number before packaging.
---

# Package Plugin

## Steps

1. **Determine which plugin to package** — default is `timmerman_skeleton_dimensions` unless the user specifies otherwise. Plugins: `timmerman_skeleton_dimensions`, `timmerman_sketchup_bridge`.

2. **Read the current version** from the plugin's loader file:
   - Skeleton Dimensions: `plugins/timmerman_skeleton_dimensions.rb` — find `EXTENSION.version = '...'`
   - Bridge: `plugins/timmerman_sketchup_bridge.rb`

3. **Bump the version** — always bump before packaging (never repackage the same version):
   - Patch bump by default (e.g. `1.0.0` → `1.0.1`), unless the user specifies a minor or major bump.
   - Update the version string in the loader file using StrReplace.

4. **Run the packager:**
   ```bash
   bash package.sh skeleton
   # or: bash package.sh bridge
   # or: bash package.sh   (builds all)
   ```

5. **Update changelog** — For Skeleton Dimensions, add an entry for the new version to `CHANGELOG.md`. Follow [Keep a Changelog](https://keepachangelog.com/) format: `## [x.y.z]` heading, then group changes under `### Added`, `### Changed`, `### Fixed`, or `### Removed` as appropriate. **Focus on user-facing features only** (what users see or get from the plugin), not internal refactors, dev tooling, or API docs. Place the new version at the top (below the header). Keep the doc covering 1.0.0 → latest.

6. **Tag and push** — after committing the version bump and changelog, create a date-based release tag and push it so GitHub Actions builds the release:
   ```bash
   today=$(date +%Y-%m-%d)
   last=$(git tag -l "release-${today}-*" | sort -t- -k4 -n | tail -1)
   n=$(( ${last##*-} + 1 ))  # defaults to 1 if none exist
   git tag "release-${today}-${n}"
   git push origin main --tags
   ```
   Tags use the format `release-YYYY-MM-DD-N` (e.g. `release-2026-02-23-1`). The count increments for multiple releases on the same day. The `.github/workflows/release.yml` workflow triggers on `release-*` tags, builds **all** plugin `.rbz` files, and attaches them to a GitHub Release.

7. **Confirm** — verify the new `.rbz` appears in `dist/` locally, and tell the user the tag has been pushed (the GitHub Release will appear shortly).

## Learnings (don't rediscover each time)

- **`dist/` is git-ignored.** The `.rbz` file is never committed. When the user asks to "package and commit", commit the version-bumped loader, plugin source files, and updated `CHANGELOG.md` (see step 5). Do not add or commit anything under `dist/`; don't report that the .rbz wasn't committed as if it were an oversight.

- **Packager command:** `bash package.sh skeleton` builds only Skeleton Dimensions; `bash package.sh bridge` builds only the bridge; `bash package.sh` builds all. The script reads the version from the loader and writes `dist/<plugin_id>-<version>.rbz`.

## Version bump rules

| Change type        | Which part to bump |
|--------------------|--------------------|
| Patch fix / tweak  | patch (x.x.**N**)  |
| New feature        | minor (x.**N**.0)  |
| Breaking change    | major (**N**.0.0)  |

Default to **patch** when in doubt.
