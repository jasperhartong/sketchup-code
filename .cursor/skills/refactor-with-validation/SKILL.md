---
name: refactor-with-validation
description: Safely refactor or DRY up SketchUp Ruby code (core.rb or similar) using the bridge. Captures a baseline of the current SketchUp output before refactoring, validates the refactored code produces identical output, then cleans up. Use when the user asks to refactor, DRY up, clean up, or restructure Ruby code that runs in SketchUp.
---

# Refactor with Validation

Safe workflow for refactoring SketchUp Ruby code: capture baseline → refactor → compare → clean up.

## Audit helper (reused in Steps 1 & 3)

**Important:** Audit only the plugin’s dimensions (same selection + sublayer as `clear`/`run`). Do **not** use `model.entities.grep(Sketchup::DimensionLinear)` — that includes every linear dimension in the model (other plugins, manual dims) and produces wrong counts (e.g. 158 instead of 49).

```ruby
def fmt_pt(pt)
  "(#{(pt.x*25.4).round(3)}, #{(pt.y*25.4).round(3)}, #{(pt.z*25.4).round(3)})mm"
end
def fmt_vec(v)
  "(#{v.x.round(6)}, #{v.y.round(6)}, #{v.z.round(6)})"
end

# dims_array: only plugin dimensions (from target_entities + sublayer), not model.entities
def audit_dims(dims_array)
  lines = []
  dims_array.each_with_index do |d, i|
    p1 = d.start[1]
    p2 = d.send(:end)[1]
    ov = d.offset_vector
    dir = Geom::Vector3d.new(p2.x - p1.x, p2.y - p1.y, p2.z - p1.z)
    normal = dir.cross(ov)
    normal.normalize! rescue nil
    lines << [
      "dim #{i}: layer='#{d.layer.name}' text='#{d.text}' 3d_dist=#{(p1.distance(p2)*25.4).round(1)}mm",
      "  p1=#{fmt_pt(p1)}  p2=#{fmt_pt(p2)}",
      "  offset=#{fmt_vec(ov)}",
      "  normal=#{fmt_vec(normal)}"
    ].join("\n")
  end
  lines.join("\n")
end

# Returns the array of DimensionLinear that belong to the plugin (current selection, maten sublayer).
def plugin_dims(model)
  inst = Timmerman::SkeletonDimensions.send(:selected_component_instance, model.selection)
  return [] unless inst
  sublayer = Timmerman::SkeletonDimensions.send(:find_or_create_maten_sublayer, model, inst)
  target = Timmerman::SkeletonDimensions.send(:entities_containing_instance, inst)
  target.grep(Sketchup::DimensionLinear).select { |d| d.layer == sublayer }
end
```

Per dimension this captures:
- **`text`** — displayed measurement (catches wrong values)
- **`p1` / `p2`** — exact 3D world-space anchor coordinates in mm (catches wrong corner/beam edge selection)
- **`3d_dist`** — scalar distance as a quick sanity check
- **`offset`** — 3D vector positioning the dim line (catches stagger, padding, top-vs-bottom, side-of-beam)
- **`normal`** — computed as `normalize((p2−p1) × offset)`; catches orientation flips that wouldn't show in the other fields. `DimensionLinear` has no built-in `normal` method, so we derive it.

## Step 1: Capture baseline

Use the **project** baseline path (`sketchup_bridge/dim_baseline.txt`) so the file is visible and not confused with other runs. When the bridge runs `command.rb`, `__dir__` is the bridge directory.

```ruby
load File.expand_path('../plugins/timmerman_skeleton_dimensions/core.rb', __dir__)
Timmerman::SkeletonDimensions.clear
Timmerman::SkeletonDimensions.run

model = Sketchup.active_model
# ... paste audit helper + plugin_dims here ...
dims = plugin_dims(model)
output = audit_dims(dims)
baseline_path = File.expand_path('dim_baseline.txt', __dir__)
timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
File.write(baseline_path, "# Baseline captured at #{timestamp}\n#{output}")
puts "BASELINE: #{dims.size} dimensions written at #{timestamp} to #{baseline_path}"
puts output
"OK"
```

Run: `ruby sketchup_bridge/run_and_wait.rb`. Confirm the printed count equals the number of dimensions the plugin created (e.g. 49).

## Step 2: Refactor

Edit the production file (`plugins/timmerman_skeleton_dimensions/core.rb`). Rules:
- No hardcoded names, IDs, or positions
- Extract repeated code into private helper methods
- Use meaningful constants for magic numbers
- Keep public API identical (`Timmerman::SkeletonDimensions.run`, `.clear`)

## Step 3: Validate

Use the **same** baseline path as Step 1 (`sketchup_bridge/dim_baseline.txt` via `File.expand_path('dim_baseline.txt', __dir__)`).

```ruby
load File.expand_path('../plugins/timmerman_skeleton_dimensions/core.rb', __dir__)
Timmerman::SkeletonDimensions.clear
Timmerman::SkeletonDimensions.run

model = Sketchup.active_model
# ... paste audit helper + plugin_dims here ...
dims = plugin_dims(model)
new_output = audit_dims(dims)

baseline_path = File.expand_path('dim_baseline.txt', __dir__)
if File.exist?(baseline_path)
  baseline_raw = File.read(baseline_path)
  baseline_header = baseline_raw.lines.first.to_s.strip
  baseline_content = baseline_raw.include?("\n") ? baseline_raw.split("\n", 2)[1] : ""
  if new_output == baseline_content
    puts "PASS: output matches baseline (#{dims.size} dimensions)"
  else
    puts "FAIL: output differs from baseline (#{baseline_header}; current: #{dims.size} dimensions)"
    old_lines = baseline_content.split("\n")
    new_lines = new_output.split("\n")
    [old_lines.size, new_lines.size].max.times do |n|
      o = old_lines[n]; nw = new_lines[n]
      if o != nw
        puts "line #{n+1} BEFORE: #{o}"
        puts "line #{n+1} AFTER:  #{nw}"
      end
    end
  end
else
  puts "WARNING: no baseline found at #{baseline_path} (run Step 1 first and ensure the bridge wrote the file)"
  puts "--- new output (#{dims.size} dimensions) ---\n#{new_output}"
end
"OK"
```

Run: `ruby sketchup_bridge/run_and_wait.rb`

- **PASS** → refactor is safe; baseline file is kept (with its timestamp) for reference or re-runs.
- **FAIL** → inspect the diff, fix the regression, and repeat from Step 3.

## Step 4: Restore normal command.rb

Once validation passes, reset `sketchup_bridge/command.rb` to the standard run command:

```ruby
load File.expand_path('../plugins/timmerman_skeleton_dimensions/core.rb', __dir__)
Timmerman::SkeletonDimensions.debug_mode = true
Timmerman::SkeletonDimensions.clear
Timmerman::SkeletonDimensions.run
"OK"
```

## Notes

- Baseline is stored at **`sketchup_bridge/dim_baseline.txt`** (project path). The first line is a timestamp, e.g. `# Baseline captured at 2025-02-22 14:30:00`, so you can see when it was captured. Step 3 compares only the content (lines after the first); the header is ignored for comparison. The baseline file is **not** deleted on PASS — it is kept so you can re-validate or compare again later.
- The **count** reported is the number of **plugin** dimensions (selection + maten sublayer), not all linear dimensions in the model. Auditing `model.entities` would include other plugins’ and manual dimensions (e.g. 158 instead of 49).
- If `Timmerman::SkeletonDimensions.run` is non-deterministic (random ordering), sort `lines` inside `audit_dims` before joining.
