# SketchUp Bridge (agent-driven iteration)

Lets Cursor/the agent run code inside SketchUp and read results **without you in the loop**.

## One-time setup

### Option A — via the bridge plugin (recommended)

1. Install `dist/timmerman_sketchup_bridge-x.x.x.rbz` in SketchUp.
2. **Extensions → SketchUp Bridge → Set Bridge Directory…** → pick this `sketchup_bridge/` folder.
3. **Extensions → SketchUp Bridge → Start Listener**.

The preference is saved; you only need to click Start on each SketchUp session (or enable auto-start).

### Option B — manual load (no plugin required)

Open **Window → Ruby Console** and run:

```ruby
load '/Users/jasper/Timmerman/sketchup-code/sketchup_bridge/listener.rb'
```

You should see: `[SketchUp Bridge] Listening. Command file: ...`

---

## How the agent iterates

1. **Agent** writes Ruby code to `sketchup_bridge/command.rb`.
2. **Agent** runs: `ruby sketchup_bridge/run_and_wait.rb`
3. **SketchUp** (within ~2–4 s) runs `command.rb` and writes stdout/stderr to `results/result.txt`.
4. **run_and_wait.rb** prints `results/result.txt` back to the agent.
5. **Agent** reads the output, edits code, and repeats.

## Files

| File | Purpose |
|---|---|
| `command.rb` | Code the agent writes and SketchUp executes. Loads `core.rb` and calls run/clear. Edit freely during iteration. |
| `run_and_wait.rb` | Agent-side runner: touches `command.rb`, waits for SketchUp to run it (up to 15 s), then prints `results/result.txt` (UTF-8). Exits 0 on success, 1 if bridge not connected. |
| `listener.rb` | Fallback manual listener (Option B). Must live in `sketchup_bridge/`; path to plugin is relative to this file. |
| `utils.rb` | Shared helpers for `command.rb` scripts. Load with `load File.expand_path('utils.rb', __dir__)`. Provides `SketchupBridgeUtils.take_screenshot`. |
| `results/` | Output folder (git-ignored contents). Contains `result.txt` (last run stdout/stderr), baselines, and screenshots. |
