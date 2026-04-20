---
name: propose-screws-from-circles
description: Convert rough circles drawn on SketchUp faces into `screw` declarations for the extendable-bed catalog. The bridge command groups circles by host+face, auto-detects mirror symmetry, picks the target FrameCatalog subclass, and emits ready-to-paste Ruby. Use when the user asks to "add screws where I drew circles" or go from rough circle indicators to `FrameCatalog` code.
---

# Propose screws from circles

**Convention:** a circle marks the **screw head entry** — the circle center is
where the head sits, and the shaft points perpendicular into the host. The
circle's diameter is ignored.

## Step 1 — Run the proposal

Swap `sketchup_bridge/command.rb` to:

```ruby
load File.expand_path('commands/propose_screws_from_circles.rb', __dir__)
'OK'
```

Then `ruby sketchup_bridge/run_and_wait.rb`.

The command groups circles by `(host, face)` and for each cluster emits:

- **target FrameCatalog subclass** (`BackFrame` if host tokens include
  `head/back/sister/mid/behind`, `FrontFrame` if `foot/front/under`),
- a suggested **method name** and the **assemble call**,
- a **ready-to-paste private method** whose body is either stacked `screw`
  declarations, or an iteration block when the cluster's u-snaps (or
  v-snaps) form a **symmetric pair summing to the face span** (u-only,
  v-only, or nested 4-corner).

All u/v values are Config expressions (`c.beam_narrow / 2.0`,
`c.beam_wide - c.beam_narrow / 3.0`, …) — never hardcoded mm.

## Step 2 — Paste

1. Paste the emitted `method_name` call into the target class's `assemble`.
2. Paste the emitted `def method_name … end` as a private method in the same
   class.
3. Optionally rename the method and the screw name strings (the emitted
   names are a slug of the host + face; rename to match existing conventions
   like `_head_cap_into_inset_leg_screws` if you want).

Use `c.<config_method>` wherever the emitted expression references a span —
keep no mm literals.

## Step 3 — Rebuild

Restore `sketchup_bridge/command.rb` to the default (rebuild) and run the
bridge. The rebuild **automatically deletes any root-level circle markers
before clearing + creating the bed**, so there's no separate cleanup step.

To verify, re-run the proposal command. Circles whose host is now an
`EB | screw | …` group are reported as "already implemented" and skipped —
that confirms the screws landed at the circle positions.

## Mirror to the other side of the bed

When the user has drawn circles on only one side (e.g. `-X`) and later asks
to mirror to `+X`, no extra proposal run is needed — rewrite the emitted
method to iterate over a host-side mapping. Example from
[`_head_corner_leg_screws`](scripts/extendable-bed/lib/frame_assembly.rb):

```ruby
{ '+X' => :max_x, '-X' => :min_x }.each do |side, outer_face|
  host = "EB | leg | head | #{side}"
  screw "EB | screw | head leg #{side} | outer-top",
        host_name: host, face: outer_face,
        u: c.beam_wide / 2.0,
        v: c.outer_corner_leg_height - c.beam_wide / 2.0,
        spec_id: :eb_pocket_4mm
end
```

u/v stay the same because each leg has identical part-local dimensions; only
the outer-face key flips (`:max_x` on +X, `:min_x` on −X).

## Pitfalls

- **Stacked concentric circles** at the same center produce duplicate
  entries in one cluster. Delete the extra in SketchUp or drop one
  declaration before pasting.
- **Circle drawn off a face** — `circle N: no host face match`. Ask the
  user to redraw on a face.
- **Face too small to host a snap** — e.g. the circle landed on an 8 mm
  screw head face. Skipped with a clear message.
- **Rotated / flipped preview roots** (`EB_StepFlip_*`) can make the mate
  probe land in a neighbour; treat `mate:` as a sanity check only — the
  `host_name`, `face`, `u`, `v` are what matter.
- **EB leaf transforms are axis-aligned translations only.** The snap math
  assumes that; rotated leaves would need a u/v rotation fix.
