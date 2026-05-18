---
name: propose-screws-from-circles
description: Convert rough circles drawn on SketchUp faces into `screw` declarations for the extendable-bed DSL spec. The bridge command groups circles by host+face, auto-detects mirror symmetry, picks the target component_group, and emits ready-to-paste Ruby. Use when the user asks to "add screws where I drew circles" or go from rough circle indicators to DSL `screw()` declarations in extendable_bed_spec.rb.
---

# Propose screws from circles

**Convention:** a circle marks the **screw head entry** — the circle center is where the head sits, the shaft points perpendicular into the host. Diameter is ignored.

## Step 1 — Run the proposal

Swap `sketchup_bridge/command.rb` to:

```ruby
load File.expand_path('commands/propose_screws_from_circles.rb', __dir__)
'OK'
```

Then `ruby sketchup_bridge/run_and_wait.rb`.

The command groups circles by `(host, face)` and emits for each cluster:

- **target `component_group`** (guessed from host name tokens — `BackFrame` vs `FrontFrame`)
- a suggested `screw` declaration in DSL format:
  ```ruby
  screw(id: "host_name_position",
        host_id: "host_part_id",
        face: :max_z,
        u: c.beam_wide / 2.0,
        v: c.beam_wide / 2.0,
        spec_id: :eb_pocket_4mm)
  ```
- u/v values as Config expressions — never hardcoded mm
- an iteration block when the cluster's u-snaps form a symmetric pair

## Step 2 — Paste into the spec

1. Open [`scripts/extendable-bed/lib/extendable_bed_spec.rb`](scripts/extendable-bed/lib/extendable_bed_spec.rb).
2. Find the correct `component_group(id: 'BackFrame')` or `component_group(id: 'FrontFrame')` block.
3. Paste each `screw(...)` declaration directly inside that block, after the `part` declarations for the host.
4. The `host_id:` must match the `id:` of a `part(...)` in the same `component_group`.

Example result in the spec:

```ruby
component_group(id: 'BackFrame') do
  part(id: 'head_corner_neg_x', kind: :beam, ...)
  screw(id: 'head_corner_neg_x_outer_top',
        host_id: 'head_corner_neg_x',
        face: :max_z,
        u: c.beam_wide / 2.0,
        v: c.beam_wide / 2.0,
        spec_id: :eb_pocket_4mm)
end
```

## Step 3 — Rebuild

Restore `sketchup_bridge/command.rb` to the default (rebuild) and run the bridge. The rebuild clears and recreates all geometry including the new screws.

To verify, re-run the proposal command. Circles whose host is now an `EB::Screw::` definition are reported as "already implemented" and skipped.

## Mirror to the other side

When circles are on one X-side only, rewrite the emitted declaration to iterate over both sides:

```ruby
['-X', '+X'].each do |side|
  face = side == '+X' ? :max_x : :min_x
  screw(id: "head_corner_#{side.downcase.tr('+', 'pos').tr('-', 'neg')}_outer_top",
        host_id: "head_corner_#{side.downcase.tr('+', 'pos').tr('-', 'neg')}",
        face: face,
        u: c.beam_wide / 2.0,
        v: c.outer_corner_leg_height - c.beam_wide / 2.0,
        spec_id: :eb_pocket_4mm)
end
```

u/v stay the same because each leg has identical part-local dimensions; only `face:` flips.

## Pitfalls

- **Stacked concentric circles** produce duplicate entries — drop the extra before pasting.
- **Circle drawn off a face** — `no host face match`. Ask the user to redraw on a face.
- **host_id not found** — the emitted `host_id` must match a `part(id:)` in the same `component_group`. Rename if the part id differs.
- **EB leaf transforms are axis-aligned translations only.** The snap math assumes that; rotated leaves need a u/v rotation fix.
