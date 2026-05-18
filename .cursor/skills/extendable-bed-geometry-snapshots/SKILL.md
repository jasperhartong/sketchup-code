---
name: extendable-bed-geometry-snapshots
description: Extendable bed geometry via named-group world AABB snapshots and the SketchUp bridge — (1) sync manual SketchUp edits into Ruby by diffing a saved target vs post-create snapshot, or (2) prove refactors unchanged by diffing a frozen baseline JSON vs post-create. Uses NamedGroupGeometrySnapshot, capture/validate bridge commands, and grep-guided edits to Config / extendable_bed_spec.
---

# Extendable bed geometry snapshots (SketchUp bridge)

Two workflows share the same tooling:

1. **Manual → code** — Capture a **target** snapshot from the edited model, patch Ruby (`Config`, `part at:/size:` in `extendable_bed_spec.rb`), re-run **`create` in SketchUp**, and **repeat until `diff(target, after_create)` is empty**.
2. **Refactor check** — Freeze the committed baseline, run `create`, **`diff_files(reference, GEOMETRY_BASELINE_JSON)`**; empty diff means geometry unchanged.

## Limitations

- Snapshots are **world-space AABBs** per **named leaf entity**. Same box with different rotation may not diff; internal face-only changes might be invisible.
- Only root-level `ComponentInstance`s whose definition names start with `"EB | "` are walked.
- Mapping **mm bbox delta → exact `at:`/`size:`** in the spec needs judgment (parent transforms, shared `Config`).

## Files and constants

- Snapshot API: [`scripts/sketchup_utils/named_group_geometry_snapshot.rb`](scripts/sketchup_utils/named_group_geometry_snapshot.rb)
- Baseline JSON: `Timmerman::ExtendableBed::Config::GEOMETRY_BASELINE_JSON` → [`scripts/extendable-bed/references/extendable_bed_geometry_baseline.json`](scripts/extendable-bed/references/extendable_bed_geometry_baseline.json)
- **Target** (manual model, stable until the loop passes): e.g. `scripts/extendable-bed/references/extendable_bed_geometry_target.json` — **do not overwrite** once captured until verification passes.
- **Refactor check**: bridge command [`sketchup_bridge/commands/validate_extendable_bed_geometry_baseline.rb`](sketchup_bridge/commands/validate_extendable_bed_geometry_baseline.rb)

## Preconditions

1. Listener running; use the bridge — do not ask the user to paste into the Ruby Console.
2. User has **not** run `clear` / `create` after manual edits (rebuild would erase them).

## Bridge: capture without rebuild

**Capture target (no rebuild):**

1. In `command.rb`, temporarily replace the default block with:
   ```ruby
   load File.expand_path('commands/capture_extendable_bed_target.rb', __dir__)
   ```
2. `ruby sketchup_bridge/run_and_wait.rb`
3. **Restore** `command.rb` immediately (`git checkout -- sketchup_bridge/command.rb`).

**Iterate after code changes:** leave the default `command.rb`, then `ruby sketchup_bridge/run_and_wait.rb`.

## Root filter (extendable bed)

In the DSL architecture, all EB roots are `ComponentInstance`s whose **definition** name starts with `"EB | "` (instances themselves may have short names like `"BedRetracted"`). Use:

```ruby
root_filter = lambda do |e|
  e.is_a?(Sketchup::ComponentInstance) &&
    e.definition.name.start_with?('EB | ')
end
```

## Step A — Capture target snapshot (once per manual session)

Swap `command.rb` to load [`sketchup_bridge/commands/capture_extendable_bed_target.rb`](sketchup_bridge/commands/capture_extendable_bed_target.rb), run `ruby sketchup_bridge/run_and_wait.rb`, restore `command.rb`.

## Step B — Map mismatches to code

For each `[MISMATCH]` / `[ADDED]` / `[MISSING]` line:

- The key is the Outliner path; the **last segment** matches the part `id:` from the DSL declaration in [`extendable_bed_spec.rb`](scripts/extendable-bed/lib/extendable_bed_spec.rb).
- **Grep** the spec for that string and for the parent `component_group(id: '...')` it lives in.
- Edit geometry: [`extendable_bed_spec.rb`](scripts/extendable-bed/lib/extendable_bed_spec.rb) — `part(id:, at:, size:)` and `instance(from_id:, at:/transform:)` declarations. Edit [`config.rb`](scripts/extendable-bed/lib/config.rb) for shared dimensions.

### Config-first and relational dimensions (critical)

- **Reuse and extend what exists** in [`config.rb`](scripts/extendable-bed/lib/config.rb). Add a new `def` there when a value is a design parameter or reused in more than one part.
- **Express geometry as alignment to other dimensions**: positions/sizes should read as relationships rather than orphan numbers.
- When a manual delta is a raw length, **interpret it**: is it a stock section, a gap, a multiple of `plank_thickness` / `beam_narrow`, or an offset from an existing chain?

### All instances share the same ComponentDefinition (critical)

In the DSL, every `instance(from_id: 'BackFrame', ...)` reference in any variant points to the **same** `ComponentDefinition`. A change to `BackFrame`'s `part` declarations affects **every** composite group that includes it.

When a mismatch appears under one variant (e.g. `BedExtended / head_corner_neg_x`):
- **Do not** branch on the variant name.
- **Do** fix the shared `part` declaration in `component_group(id: 'BackFrame')` so every bed variant updates.
- Use `hidden_components: [...]` on a specific `instance()` call only when one variant **intentionally** omits a part.

## Step C — Mandatory iteration until snapshots match

**Do not stop after a single edit.** After every code change:

1. Run `ruby sketchup_bridge/run_and_wait.rb` (rebuilds).
2. `GEOMETRY_BASELINE_JSON` is refreshed by `create`; diff that file against the target.
3. **If `issues.any?`**: print the list, patch code, go to step 1.
4. **If `issues.empty?`**: print **`PASS: snapshots match`** and stop.

## Refactor regression check (geometry must stay identical)

1. **Freeze reference:** `cp scripts/extendable-bed/references/extendable_bed_geometry_baseline.json /tmp/eb_geometry_baseline_ref.json`
2. **Swap** `command.rb` to:
   ```ruby
   load File.expand_path('commands/validate_extendable_bed_geometry_baseline.rb', __dir__)
   ```
3. `ruby sketchup_bridge/run_and_wait.rb` — expect **`PASS: geometry snapshot matches reference`**.
4. **Restore** `command.rb`.
