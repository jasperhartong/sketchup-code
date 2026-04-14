---
name: sketchup-git-history-gif
description: Build an animated GIF of SketchUp screenshots, one per git revision of a Ruby script, using the bridge and ffmpeg. Use for extendable bed evolution visuals or any generator tracked in git; supports presets and custom CLI.
---

# SketchUp git-history GIF

Walks **git history** (oldest → newest) for a chosen **repo-relative file**, checks out each revision into the worktree, runs **SketchUp via the bridge** to `load` that file and run follow-up Ruby (e.g. `clear` + `create`), captures a screenshot per commit, then runs **ffmpeg** to assemble a GIF.

## Prerequisites

- **SketchUp** with the bridge listener; bridge directory = repo [`sketchup_bridge/`](sketchup_bridge/).
- **ffmpeg** on `PATH`.
- **Disposable model** — each frame optionally **erases all top-level entities** before rebuild so geometry does not stack. Do not use on production `.skp` files you care about.
- The tracked file must be **loadable in SketchUp** at every commit you include (very old SHAs may error; the script stops and restores backups).

## Extendable bed (default)

From repo root:

```bash
ruby scripts/sketchup_utils/capture_git_history_gif.rb --preset extendable-bed
```

Equivalent:

```bash
ruby scripts/extendable-bed/capture_git_history_gif.rb
```

Optional flags (apply to any mode): `--dry-run`, `--fps 1.2`, `--no-dedupe`, `--width`, `--height`, `SKETCHUP_BRIDGE_MAX_WAIT=60`.

- **Dry run** (list commits only): `--dry-run`
- **Dry run + write manifest** (no SketchUp): `--dry-run --write-dry-manifest` (requires `--out-manifest` from preset; preset supplies it)

Outputs (preset): `scripts/extendable-bed/references/extendable-bed-git-history.gif`, `…-manifest.json`, PNG frames under `sketchup_bridge/results/` with prefix `eb_git_hist_`.

## Generic: another script

Add a **preset** in [`scripts/sketchup_utils/capture_git_history_gif.rb`](scripts/sketchup_utils/capture_git_history_gif.rb) (`PRESETS` hash) with `git_path`, `load_rel` (path relative to `sketchup_bridge/` for `File.expand_path`), `eval_after_load`, `out_gif`, `manifest`, `frame_prefix`, and optional `clear_model` / `clear_operation_name`.

Or pass everything on the CLI (no preset):

```bash
ruby scripts/sketchup_utils/capture_git_history_gif.rb \
  --repo . \
  --git-path scripts/my-tool/run.rb \
  --load-rel ../scripts/my-tool/run.rb \
  --eval-after-load "MyTool.reset; MyTool.build" \
  --out-gif references/my-tool-history.gif \
  --out-manifest references/my-tool-history-manifest.json \
  --frame-prefix mytool_hist
```

Use `--eval-file path/to/after_load.rb` for multi-line SketchUp Ruby (paths are repo-relative). Use `--no-clear-model` if the script manages the model itself. Use `--worktree PATH` if the file git tracks is not the same path you want overwritten (unusual).

## Agent workflow

1. Confirm **ffmpeg** and **bridge** availability; warn about **wiping the model** when `clear_model` is true.
2. Prefer `--dry-run` first to show commit count and subjects.
3. Run the full command from **repo root**; on failure, read `sketchup_bridge/results/result.txt` tail.
4. The script **restores** the worktree file and `sketchup_bridge/command.rb` in `ensure`; do not rely on manual revert.

## Implementation reference

- [`scripts/sketchup_utils/capture_git_history_gif.rb`](scripts/sketchup_utils/capture_git_history_gif.rb) — all logic and `PRESETS`.
- [`scripts/extendable-bed/capture_git_history_gif.rb`](scripts/extendable-bed/capture_git_history_gif.rb) — `exec` launcher with `--preset extendable-bed`.
