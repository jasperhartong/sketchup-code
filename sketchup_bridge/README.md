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
3. **SketchUp** (within ~2–4 s) runs `command.rb` and writes stdout/stderr to `result.txt`.
4. **run_and_wait.rb** prints `result.txt` back to the agent.
5. **Agent** reads the output, edits code, and repeats.

## Files

| File | Purpose |
|---|---|
| `command.rb` | Code the agent writes and SketchUp executes. Loads `core.rb` and calls run/clear. Edit freely during iteration. |
| `run_and_wait.rb` | Agent-side runner: waits for SketchUp to process `command.rb`, then prints `result.txt`. |
| `listener.rb` | Fallback manual listener (Option B above). |
| `result.txt` | Last execution output — git-ignored. |
| `.last_run` | Timestamp sentinel used by the listener — git-ignored. |
