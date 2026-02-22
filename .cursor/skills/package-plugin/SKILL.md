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
   cd /Users/jasper/Timmerman/sketchup-code && bash package.sh skeleton
   # or: bash package.sh bridge
   # or: bash package.sh   (builds all)
   ```

5. **Update release notes** — For Skeleton Dimensions, add an entry for the new version to `RELEASE_NOTES.md`. **Focus on user-facing features only** (what users see or get from the plugin), not internal refactors, dev tooling, or API docs. Same format: version heading, bullet list of highlights with emoji (e.g. **🧹 Labels** — …). **Use a "bugfix: " prefix** for bullets that describe a bug fix (e.g. **bugfix: 🧹 Labels** — …). Place the new version at the top of its minor section (e.g. new 1.3.4 under “1.3.x”); create a new “1.x.x” section if it’s a new minor/major. Keep the doc covering 1.0.0 → latest.

6. **Confirm** — verify the new `.rbz` appears in `dist/` and report the filename to the user.

## Learnings (don't rediscover each time)

- **`dist/` is git-ignored.** The `.rbz` file is never committed. When the user asks to "package and commit", commit the version-bumped loader, plugin source files, and updated `RELEASE_NOTES.md` (see step 5). Do not add or commit anything under `dist/`; don't report that the .rbz wasn't committed as if it were an oversight.

- **Packager command:** `bash package.sh skeleton` builds only Skeleton Dimensions; `bash package.sh bridge` builds only the bridge; `bash package.sh` builds all. The script reads the version from the loader and writes `dist/<plugin_id>-<version>.rbz`.

## Version bump rules

| Change type        | Which part to bump |
|--------------------|--------------------|
| Patch fix / tweak  | patch (x.x.**N**)  |
| New feature        | minor (x.**N**.0)  |
| Breaking change    | major (**N**.0.0)  |

Default to **patch** when in doubt.
