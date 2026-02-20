# SketchUp Bridge (agent-driven iteration)

Lets Cursor/the agent run code inside SketchUp and read results **without you in the loop**.

## One-time setup per SketchUp session

1. Open SketchUp (with or without `-rdebug`).
2. **Window → Ruby Console** and run:
   ```ruby
   load '/Users/jasper/Timmerman/sketchup-code/sketchup_bridge/listener.rb'
   ```
3. You should see: `[SketchUp Bridge] Listening. Command file: ...`

Leave SketchUp open. The listener polls every 2 seconds.

## How the agent iterates

1. **Agent** writes Ruby code to `sketchup_bridge/command.rb` (e.g. load your scripts, select something, call `Dimensions.run`).
2. **Agent** runs: `ruby sketchup_bridge/run_and_wait.rb`
3. **SketchUp** (within ~2–4 s) runs `command.rb`, writes stdout/stderr to `sketchup_bridge/result.txt`.
4. **run_and_wait.rb** prints the contents of `result.txt`.
5. **Agent** reads the output, edits code, and repeats.

No pasting in the Ruby Console; the agent only edits files and runs the runner script.

## Optional: run on current selection

To run on whatever is **currently selected** in SketchUp (no name lookup), use this as `command.rb`:

```ruby
project_root = File.expand_path(File.join(File.dirname(__FILE__), '..'))
load File.join(project_root, 'Dimensions.rb')
Dimensions.clear
Dimensions.run
"OK"
```

To run on a **specific instance by name** (e.g. `test001`), the default `command.rb` already does that: it finds an instance with `definition.name == 'test001'`, selects it, then runs `Dimensions.clear` and `Dimensions.run`.
