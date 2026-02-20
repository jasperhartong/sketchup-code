# sketchup-code

SketchUp Ruby scripts for wooden skeleton structures, with an agent-driven iteration bridge and a safe refactor workflow.

## Scripts

| File | Purpose |
|---|---|
| `Dimensions.rb` | Adds cumulative, per-beam, and diagonal dimensions to a selected component. Run `Dimensions.run` after selecting one component instance. |

## SketchUp Bridge

The bridge lets the Cursor agent run Ruby code inside SketchUp and read the results — no manual pasting in the Ruby Console.

**One-time setup per SketchUp session:**

```ruby
load '/Users/jasper/Timmerman/sketchup-code/sketchup_bridge/listener.rb'
```

After that the agent edits `sketchup_bridge/command.rb`, runs `ruby sketchup_bridge/run_and_wait.rb`, and reads the output. SketchUp executes the command within ~2–4 s.

See [`sketchup_bridge/README.md`](sketchup_bridge/README.md) for full details.

## Refactor with Validation (Cursor skill)

The `.cursor/skills/refactor-with-validation` skill provides a safe workflow for cleaning up Ruby code without breaking anything:

1. **Capture baseline** — runs the current code via the bridge and saves every dimension's anchor coordinates, offset vector, and computed normal to `/tmp/dim_baseline.txt`.
2. **Refactor** — edit `Dimensions.rb` (or any production file).
3. **Validate** — re-runs via the bridge and diffs the new output against the baseline line-by-line. Prints `PASS` and deletes the baseline on a match; prints the exact changed lines on a mismatch.
4. **Restore** — resets `command.rb` to the standard run command.

Trigger it by attaching the skill in Cursor and typing `/refactor-with-validation`.
