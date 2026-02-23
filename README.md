# sketchup-code

SketchUp Ruby scripts for wooden skeleton structures, with an agent-driven iteration bridge and a safe refactor workflow.

## Plugin — Skeleton Dimensions

A distributable SketchUp extension that adds cumulative, per-beam, and diagonal
dimensions to wooden skeleton components.

### Directory layout

```
plugins/
  timmerman_skeleton_dimensions.rb          ← extension loader (goes in Plugins/)
  timmerman_skeleton_dimensions/
    core.rb                                 ← algorithm (single source of truth)
    main.rb                                 ← thin loader: load core.rb + ui.rb
    ui.rb                                   ← Extensions menu + toolbar
  timmerman_sketchup_bridge.rb              ← bridge extension loader
  timmerman_sketchup_bridge/
    core.rb                                 ← listener logic (single source of truth)
    main.rb                                 ← thin loader: load core.rb + ui.rb
    ui.rb                                   ← Extensions menu
dist/
  timmerman_skeleton_dimensions-1.0.0.rbz  ← built package (git-ignored)
  timmerman_sketchup_bridge-1.0.0.rbz      ← built package (git-ignored)
```

### Building the .rbz

```bash
./package.sh                 # build all plugins
./package.sh skeleton        # build only skeleton_dimensions
./package.sh bridge          # build only sketchup_bridge
# → dist/<plugin>-<version>.rbz
```

Bump the version by editing the `EXTENSION.version` line in the plugin's loader file in `plugins/`.

### Installing

1. In SketchUp: **Window → Extension Manager → Install Extension…**
2. Select the `.rbz` file.
3. Restart SketchUp if prompted.

### Usage

Select exactly one component instance in your model, then:

- **Extensions → Skeleton Dimensions → Add Dimensions** — annotates the skeleton.
- **Extensions → Skeleton Dimensions → Clear Dimensions** — removes all linear dimensions.

Both commands are also available on the **Skeleton Dimensions** toolbar.

---

## Development

The algorithm lives in **`plugins/timmerman_skeleton_dimensions/core.rb`** — the single source of truth. The bridge's `command.rb` loads it directly for iteration; the plugin's `main.rb` loads it for production. No duplication.

To iterate: edit `core.rb`, run the bridge, inspect output. When ready, run `./package.sh` to produce a new `.rbz`.

## SketchUp Bridge

The bridge lets the Cursor agent run Ruby code inside SketchUp and read the results — no manual pasting in the Ruby Console.

### Option A — via the bridge plugin (recommended)

1. Install `dist/timmerman_sketchup_bridge-1.0.0.rbz` in SketchUp.
2. **Extensions → SketchUp Bridge → Set Bridge Directory…** → pick this project's `sketchup_bridge/` folder.
3. **Extensions → SketchUp Bridge → Start Listener** — the listener now runs automatically each session.

The listener restarts itself whenever you click Start; use Stop to pause it.

### Option B — manual load (no plugin required)

```ruby
load '/Users/jasper/Timmerman/sketchup-code/sketchup_bridge/listener.rb'
```

### Agent workflow (both options)

The agent edits `sketchup_bridge/command.rb`, runs `ruby sketchup_bridge/run_and_wait.rb`, and reads the output. SketchUp executes the command within ~2–4 s.

See [`sketchup_bridge/README.md`](sketchup_bridge/README.md) for full details.

## Refactor with Validation (Cursor skill)

The `.cursor/skills/refactor-with-validation` skill provides a safe workflow for cleaning up Ruby code without breaking anything:

1. **Capture baseline** — runs the current code via the bridge and saves every dimension's anchor coordinates, offset vector, and computed normal to `sketchup_bridge/results/dim_baseline.txt`.
2. **Refactor** — edit `plugins/timmerman_skeleton_dimensions/core.rb`.
3. **Validate** — re-runs via the bridge and diffs the new output against the baseline line-by-line. Prints `PASS` and deletes the baseline on a match; prints the exact changed lines on a mismatch.
4. **Restore** — resets `command.rb` to the standard run command.

Trigger it by attaching the skill in Cursor and typing `/refactor-with-validation`.
