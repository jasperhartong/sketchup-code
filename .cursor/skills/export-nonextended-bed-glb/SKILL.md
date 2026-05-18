---
name: export-nonextended-bed-glb
description: Export the extendable bed retracted (non-extended) preview to native .glb via the SketchUp bridge — hides other EB roots, runs Model#export, restores visibility. Use when the user wants a single-bed GLB, game-engine handoff, or CI artifact from the live model.
---

# Export non-extended bed (native GLB)

## What gets exported

- Only the **retracted** composite group: `EB | BedRetracted` — the full bed assembly at retracted length, built from `BackFrame` + `FrontFrame` + pillows.
- **SketchUp 2024+** required for `Sketchup::Model#export` with a `.glb` path ([`Model#export`](https://ruby.sketchup.com/Sketchup/Model.html#export-instance_method)).
- Implementation: [`scripts/extendable-bed/lib/export_nonextended_bed_glb.rb`](scripts/extendable-bed/lib/export_nonextended_bed_glb.rb) — temporarily hides all other root drawing elements, exports, then restores visibility.

## Bridge run (preferred)

1. Ensure the model has a fresh **`clear` + `create`** so `EB | BedRetracted` exists.
2. Temporarily set [`sketchup_bridge/command.rb`](sketchup_bridge/command.rb) to:
   ```ruby
   load File.expand_path('commands/export_nonextended_bed_glb.rb', __dir__)
   ```
3. Run `ruby sketchup_bridge/run_and_wait.rb`.
4. Restore `command.rb` (default rebuild command).

**Output path**

- Default: `sketchup_bridge/results/extendable_bed_nonextended.glb`
- Override: set `EB_GLB_PATH` before `run_and_wait`, e.g. `EB_GLB_PATH=out/bed.glb ruby sketchup_bridge/run_and_wait.rb`

## In-console / other scripts

```ruby
load '/path/to/scripts/extendable-bed/extendable-bed.rb'
load '/path/to/scripts/extendable-bed/lib/export_nonextended_bed_glb.rb'
Timmerman::ExtendableBed::GlbExport.export_nonextended_pair('/tmp/bed.glb')
```

## Changing the export target

Edit the `roots` array in `GlbExport#export_nonextended_pair` (currently `['EB | BedRetracted']`) if a different variant should be exported — e.g. `'EB | BedExtended'` for the fully-extended bed. Root names match the `component_group(id: '...')` declarations in [`extendable_bed_spec.rb`](scripts/extendable-bed/lib/extendable_bed_spec.rb) prefixed with `"EB | "`.
