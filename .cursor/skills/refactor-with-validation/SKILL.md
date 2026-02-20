---
name: refactor-with-validation
description: Safely refactor or DRY up SketchUp Ruby code (core.rb or similar) using the bridge. Captures a baseline of the current SketchUp output before refactoring, validates the refactored code produces identical output, then cleans up. Use when the user asks to refactor, DRY up, clean up, or restructure Ruby code that runs in SketchUp.
---

# Refactor with Validation

Safe workflow for refactoring SketchUp Ruby code: capture baseline → refactor → compare → clean up.

## Audit helper (reused in Steps 1 & 3)

```ruby
def fmt_pt(pt)
  "(#{(pt.x*25.4).round(3)}, #{(pt.y*25.4).round(3)}, #{(pt.z*25.4).round(3)})mm"
end
def fmt_vec(v)
  "(#{v.x.round(6)}, #{v.y.round(6)}, #{v.z.round(6)})"
end

def audit_dims(model)
  lines = []
  model.entities.grep(Sketchup::DimensionLinear).each_with_index do |d, i|
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
```

Per dimension this captures:
- **`text`** — displayed measurement (catches wrong values)
- **`p1` / `p2`** — exact 3D world-space anchor coordinates in mm (catches wrong corner/beam edge selection)
- **`3d_dist`** — scalar distance as a quick sanity check
- **`offset`** — 3D vector positioning the dim line (catches stagger, padding, top-vs-bottom, side-of-beam)
- **`normal`** — computed as `normalize((p2−p1) × offset)`; catches orientation flips that wouldn't show in the other fields. `DimensionLinear` has no built-in `normal` method, so we derive it.

## Step 1: Capture baseline

```ruby
load File.expand_path('../plugins/timmerman_skeleton_dimensions/core.rb', __dir__)
Timmerman::SkeletonDimensions.clear
Timmerman::SkeletonDimensions.run

model = Sketchup.active_model
# ... paste audit helper here ...
output = audit_dims(model)
File.write('/tmp/dim_baseline.txt', output)
puts "BASELINE (#{output.lines.count { |l| l.start_with?('dim ') }} dims):\n#{output}"
"OK"
```

Run: `ruby sketchup_bridge/run_and_wait.rb`

## Step 2: Refactor

Edit the production file (`plugins/timmerman_skeleton_dimensions/core.rb`). Rules:
- No hardcoded names, IDs, or positions
- Extract repeated code into private helper methods
- Use meaningful constants for magic numbers
- Keep public API identical (`Timmerman::SkeletonDimensions.run`, `.clear`)

## Step 3: Validate

```ruby
load File.expand_path('../plugins/timmerman_skeleton_dimensions/core.rb', __dir__)
Timmerman::SkeletonDimensions.clear
Timmerman::SkeletonDimensions.run

model = Sketchup.active_model
# ... paste audit helper here ...
new_output = audit_dims(model)

baseline_path = '/tmp/dim_baseline.txt'
if File.exist?(baseline_path)
  baseline = File.read(baseline_path)
  if new_output == baseline
    puts "PASS: output matches baseline (#{new_output.lines.count { |l| l.start_with?('dim ') }} dims)"
    File.delete(baseline_path)
  else
    puts "FAIL: output differs from baseline"
    old_lines = baseline.split("\n")
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
  puts "WARNING: no baseline found at #{baseline_path}"
  puts "--- new output ---\n#{new_output}"
end
"OK"
```

Run: `ruby sketchup_bridge/run_and_wait.rb`

- **PASS** → refactor is safe; baseline file is auto-deleted.
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

- Baseline is stored at `/tmp/dim_baseline.txt`. If Step 3 is never reached (crash, etc.), delete it manually.
- If `Timmerman::SkeletonDimensions.run` is non-deterministic (random ordering), sort `lines` before writing/comparing.
