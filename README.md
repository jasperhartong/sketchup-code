# SketchUp Code

> This README (and most of the code in this repo) was written by an AI agent (Claude) in Cursor — using the very bridge described below.

An AI-agent-driven development workflow for SketchUp Ruby plugins. The core of this repo is the **SketchUp Bridge** — a file-based protocol that lets an AI coding agent (Cursor, etc.) execute Ruby code inside a running SketchUp instance and read back the results, without any manual copy-pasting in the Ruby Console.

The repo also includes **Skeleton Dimensions**, a real SketchUp plugin built and iterated entirely through this workflow.

## Requirements

- **SketchUp 2026** (tested). Should work with SketchUp 2024+ (Ruby 3.x bundled), but only 2026 is actively tested.

## SketchUp Bridge

The bridge connects your editor to a running SketchUp instance. The agent writes Ruby to a file, SketchUp executes it, and the result comes back — all within a few seconds.

### How it works

1. A **listener** runs inside SketchUp, watching `sketchup_bridge/command.rb` for changes.
2. The agent writes code to `command.rb` and runs `ruby sketchup_bridge/run_and_wait.rb`.
3. SketchUp executes the command and writes stdout/stderr to `sketchup_bridge/results/result.txt`.
4. `run_and_wait.rb` returns the output to the agent, which reads it and iterates.

### Setup

**Option A — bridge plugin (recommended):**

1. Build with `./package.sh bridge` (or grab a pre-built `.rbz` from `dist/`).
2. Install in SketchUp: **Window → Extension Manager → Install Extension…**
3. **Extensions → SketchUp Bridge → Set Bridge Directory…** → pick this project's `sketchup_bridge/` folder.
4. **Extensions → SketchUp Bridge → Start Listener**.

The preference is saved; click Start once per SketchUp session.

**Option B — manual load (no plugin required):**

```ruby
load File.join('<path-to-this-repo>', 'sketchup_bridge', 'listener.rb')
```

See [`sketchup_bridge/README.md`](sketchup_bridge/README.md) for full details.

### Cursor integration

The `.cursor/` directory includes rules and skills that teach the Cursor agent how to use the bridge:

- **`.cursor/rules/sketchup-bridge.mdc`** — always-on rule: the agent uses the bridge automatically for any SketchUp iteration (diagnose, fix, validate).
- **`.cursor/skills/refactor-with-validation/`** — safe refactoring workflow: capture a baseline of all dimensions, refactor, then diff against the baseline to confirm nothing changed.
- **`.cursor/skills/package-plugin/`** — packaging workflow: bump version, build `.rbz`, update changelog.
- **`.cursor/rules/sketchup-ruby-api-docs.mdc`** — SketchUp Ruby API quick reference, kept up to date as the agent discovers new methods.

---

## Example plugin — Skeleton Dimensions

A distributable SketchUp extension that adds cumulative, per-beam, and diagonal dimensions to wooden skeleton components. Built and iterated entirely through the bridge.

### Usage

Select exactly one component instance in your model, then:

- **Extensions → Skeleton Dimensions → Add Dimensions** — annotates the skeleton.
- **Extensions → Skeleton Dimensions → Clear Dimensions** — removes all added dimensions.

Both commands are also available on the **Skeleton Dimensions** toolbar.

---

## Project layout

```
plugins/
  timmerman_skeleton_dimensions.rb        ← extension loader
  timmerman_skeleton_dimensions/
    core.rb                               ← algorithm (single source of truth)
    helpers.rb                            ← helper functions
    dimension_cumulative.rb               ← cumulative dimension logic
    label.rb                              ← version label
    main.rb                               ← thin loader: core.rb + ui.rb
    ui.rb                                 ← Extensions menu + toolbar
  timmerman_sketchup_bridge.rb            ← bridge extension loader
  timmerman_sketchup_bridge/
    core.rb                               ← listener logic
    main.rb                               ← thin loader: core.rb + ui.rb
    ui.rb                                 ← Extensions menu
sketchup_bridge/
  command.rb                              ← agent writes code here
  run_and_wait.rb                         ← agent-side runner
  listener.rb                             ← manual listener fallback
  utils.rb                                ← helpers (screenshots, etc.)
  results/                                ← output (git-ignored)
dist/                                     ← built .rbz packages (git-ignored)
```

## Building

```bash
./package.sh                 # build all plugins
./package.sh skeleton        # build only skeleton_dimensions
./package.sh bridge          # build only sketchup_bridge
```

Bump the version by editing the `EXTENSION.version` line in the plugin's loader file in `plugins/`.

## Installing a plugin

1. In SketchUp: **Window → Extension Manager → Install Extension…**
2. Select the `.rbz` file from `dist/`.
3. Restart SketchUp if prompted.

## Development

The plugin algorithm lives in `plugins/timmerman_skeleton_dimensions/core.rb` — the single source of truth. The bridge's `command.rb` loads it directly for iteration; the plugin's `main.rb` loads it for production. No duplication.

To iterate: edit `core.rb`, run the bridge, inspect output. When ready, `./package.sh` produces a new `.rbz`.

## License

[MIT](LICENSE)
