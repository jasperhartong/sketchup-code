---
name: export-nonextended-bed-glb
description: Export the extendable bed retracted (non-extended) preview pair to native .glb via the SketchUp bridge — hides other EB roots, runs Model#export, restores visibility. Use when the user wants a single-bed GLB, game-engine handoff, or CI artifact from the live model.
---

# Export non-extended bed (native GLB)

## What gets exported

- Only the **retracted** preview pair: `EB_Ret_Back` + `EB_Ret_Front` (full assembly at retracted length). Names are defined as `Config::NONEXTENDED_GLB_EXPORT_ROOTS` in [`scripts/extendable-bed/lib/config.rb`](scripts/extendable-bed/lib/config.rb).
- **SketchUp 2024+** required for `Sketchup::Model#export` with a `.glb` path ([`Model#export`](https://ruby.sketchup.com/Sketchup/Model.html#export-instance_method)).
- Implementation: [`scripts/extendable-bed/lib/export_nonextended_bed_glb.rb`](scripts/extendable-bed/lib/export_nonextended_bed_glb.rb) — temporarily sets `hidden` on other root drawing elements, exports, then restores (GLB exporter does not document `selectionset_only` in [exporter options](https://ruby.sketchup.com/file.exporter_options.html)).

## Bridge run (preferred)

1. Ensure the model has a fresh **`clear` + `create`** (and optional step labels) so `EB_Ret_*` groups exist.
2. Temporarily set [`sketchup_bridge/command.rb`](sketchup_bridge/command.rb) to load only:
   ```ruby
   load File.expand_path('commands/export_nonextended_bed_glb.rb', __dir__)
   ```
3. Run `ruby sketchup_bridge/run_and_wait.rb`.
4. Restore `command.rb` (default rebuild command).

**Output path**

- Default: `sketchup_bridge/results/extendable_bed_nonextended.glb` under the repo.
- Override: set `EB_GLB_PATH` before `run_and_wait` (absolute path, or relative to repo root), e.g. `EB_GLB_PATH=out/bed.glb`.

## In-console / other scripts

After loading extendable bed + the export library:

```ruby
load '/path/to/scripts/extendable-bed/extendable-bed.rb'
load '/path/to/scripts/extendable-bed/lib/export_nonextended_bed_glb.rb'
Timmerman::ExtendableBed::GlbExport.export_nonextended_pair('/tmp/bed.glb')
```

## Changing the export target

Edit `Config::NONEXTENDED_GLB_EXPORT_ROOTS` (and this skill) if the product should ship a different pair (e.g. only construction Step 7 roots). Keep names aligned with [`construction_steps.rb`](scripts/extendable-bed/lib/construction_steps.rb) / [`config.rb`](scripts/extendable-bed/lib/config.rb).
