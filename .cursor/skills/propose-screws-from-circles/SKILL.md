---
name: propose-screws-from-circles
description: Convert rough circles drawn on SketchUp faces into fully-specified `screw` declarations for the extendable-bed catalog. The bridge command finds each circle's host EB part + face, identifies the mate part on the other side (scoped to the same preview root), and snaps u/v to 1/3 of `beam_narrow` or `beam_wide` measured from the face end nearest the circle — no hardcoded mm. Use when the user asks to "add screws where I drew circles" or to go from rough circle indicators to `FrameCatalog` screw code.
---

# Propose screws from circles

Turn rough user-drawn circles (approximate screw-head positions) into clean
`screw '…', host_name:, face:, u:, v:, spec_id:` declarations that reference
only `Config` values (`beam_narrow`, `beam_wide`, and face spans).

**Convention:** a circle marks the **screw head entry** — the center of the
circle is where the head sits on the face, and the shaft points perpendicular
into the host. The circle's **diameter is ignored** (the visual screw
diameter is driven by `ScrewSpec#shaft_diameter`).

## Inputs (what the user provides)

- One or more full circles drawn **on a face of an EB leaf part** in the
  active SketchUp model.
- Circles should be at the **model root** (the default scan scope). If the
  user has them in a group or nested elsewhere, they should **select** them
  before running — selection wins over the root scan.

## What the command proposes (the rules)

For each circle center the command computes:

1. **Host part + face** — the EB leaf part whose face plane the center sits
   on, and the face key (`:min_x` / `:max_x` / `:min_y` / `:max_y` /
   `:min_z` / `:max_z`). The circle's normal picks the axis; whichever of
   `(min, max)` face on that axis is closer to the center wins.
2. **Mate part** — the EB leaf part whose world AABB contains a probe point
   just past the host's far face along the screw axis (= face inward
   normal). That's the part the screw fastens **into**.
3. **Snapped `u` and `v`** — for each face axis, emit exactly one offset
   picked from `{beam_narrow/3, beam_narrow/2, beam_wide/3, beam_wide/2}`
   measured from the face end nearest to the circle center along that
   axis. The winning candidate is the one closest to the circle's u/v.
   Emitted as Ruby expressions (e.g. `c.beam_narrow / 2.0`,
   `c.outer_corner_leg_height - c.beam_wide / 3.0`) — no hardcoded mm
   numbers. No other snap values are allowed. When `span - offset`
   equals the offset (i.e. the offset lands on the axis center), the
   shorter form is emitted.
4. **`spec_id`** — always `:eb_pocket_4mm` (the only family). The current
   spec has a single shaft length (`2 · beam_narrow` = 88 mm), so
   `shaft_length_index` is omitted (defaults to 0). If a future job needs a
   different length, extend `Config#screw_specs[:eb_pocket_4mm].shaft_lengths`
   first (use a `Config` expression, not a raw mm literal), then pass
   `shaft_length_index: N` on the screw declaration.

## Step 1 — Run the discovery command

Swap `sketchup_bridge/command.rb` to load the proposal script only:

```ruby
load File.expand_path('commands/propose_screws_from_circles.rb', __dir__)
'OK'
```

Then:

```bash
ruby sketchup_bridge/run_and_wait.rb
```

Expect output like this per circle:

```
  ── circle 0 ──
    host:       EB | leg | head | +X  (in EB_StepPrep_Back)
    face:       min_y   (screw head at this face; screw axis perpendicular into host)
    face u/v:   u(X)=44.0 mm   v(Z)=191.0 mm
    circle u/v: u=21.2 mm   v=15.2 mm
    → u snap:   14.7 mm  (beam_narrow/3 from min)
    → v snap:   14.7 mm  (beam_narrow/3 from min)
    host thickness along screw axis: 69.0 mm
    mate through host: EB | beam | head | end
    shaft length (only available): 88.0 mm

    # paste inside the appropriate FrameCatalog subclass:
    screw 'EB | screw | TODO name | 0',
          host_name: 'EB | leg | head | +X',
          face:      :min_y,
          u:         c.beam_narrow / 3.0,
          v:         c.beam_narrow / 3.0,
          spec_id:   :eb_pocket_4mm
```

## Step 2 — Insert the proposals in code

For each proposed screw:

1. Pick a **meaningful name** (replace `TODO name`, e.g.
   `'EB | screw | head +X leg | front lower'`). Keep the `EB | screw | …`
   prefix so `Config::SCREW_NAME_RE` still matches on clear.
2. Decide which `FrameCatalog` subclass to edit based on the `host_name`:
   - Host starts with `head` / `back` → [`BackFrame`](scripts/extendable-bed/lib/frame_assembly.rb)
   - Host starts with `foot` / `front` → [`FrontFrame`](scripts/extendable-bed/lib/frame_assembly.rb)
3. Add a private method named after the host (e.g. `_head_corner_leg_px_screws`),
   containing the pasted declarations, and call it from `assemble`. Existing
   examples in the same file:
   [`_head_end_beam_into_slats_screws`](scripts/extendable-bed/lib/frame_assembly.rb#L181)
   and [`_foot_end_beam_into_slats_screws`](scripts/extendable-bed/lib/frame_assembly.rb#L325).
4. **Do not** introduce hardcoded mm values — keep the emitted expressions
   (`c.beam_narrow / 3.0`, etc.).

## Step 3 — Rebuild and audit

Restore `sketchup_bridge/command.rb` to the default (rebuild) and run the
bridge. Then validate by re-running the proposal command: each proposed
screw's host/face/u/v should now also be occupied by an actual
`EB | screw | …` group in the model. Optionally take a screenshot via
`SketchupBridgeUtils.take_screenshot` to confirm visually.

Circles drawn at the model root are **not** wiped by the extendable-bed
`clear` (which only touches `EB_*` roots), so they persist across rebuilds
until explicitly deleted.

## Mirror convention (after the proposal lands in code)

When the user asks to **mirror a pair of screws to the other side** of the
bed, no extra proposal run is needed — the geometry is already a clean
X-centerline reflection. Rewrite the method to iterate over a side → outer
face mapping instead of duplicating declarations:

```ruby
{ '+X' => :max_x, '-X' => :min_x }.each do |side, outer_face|
  host = "EB | leg | head | #{side}"

  screw "EB | screw | head leg #{side} | outer-top",
        host_name: host,
        face:      outer_face,
        u:         c.beam_wide / 2.0,
        v:         c.outer_corner_leg_height - c.beam_wide / 2.0,
        spec_id:   :eb_pocket_4mm

  # …mirrored `:min_y` screws, `u`/`v` unchanged…
end
```

Why `u`/`v` stay the same: each head corner leg has identical part-local
dimensions (44 × 69 × 191 mm), so a position expressed in the leg's local
frame is automatically symmetric. Only the *outer*-face key flips
(`:max_x` vs `:min_x`) because "outer" means a different local face on
each side of the bed. Head-facing (`:min_y`) and foot-facing (`:max_y`)
faces are the same key on both sides.

For front/foot legs, apply the same pattern to `FrontFrame` and the
corresponding `EB | leg | foot | ±X` hosts.

## Step 4 — Delete the marker circles (only when the user confirms)

When the user says something like *"looks good"*, *"the positioning is
correct"*, *"I'm ok with the positioning"*, or *"you can remove the
circles"*, run the dedicated cleanup command. **Do not** delete circles
proactively — always wait for the user's confirmation that the rendered
screws match their intent.

Swap `sketchup_bridge/command.rb` to:

```ruby
load File.expand_path('commands/delete_proposal_circles.rb', __dir__)
```

Then run `ruby sketchup_bridge/run_and_wait.rb`. The command erases every
full-circle edge ring at the model root (same scope the proposal script
scans) and reports how many it removed. Restore `command.rb` to the default
rebuild afterwards.

## Pitfalls

- **Multiple circles stacked at the same center** (e.g. two concentric
  circles) — both are emitted as separate proposals with the same host/u/v;
  either delete the duplicate in SketchUp, or only paste one.
- **Circle drawn off a face** — `host` match fails; the command prints
  `NO host face match`. Ask the user to redraw the circle on a face.
- **No mate found** — the screw would exit into open air. Either the host
  is standalone or the circle is on the wrong face of the host. Review
  before pasting.
- **Mate reported seems far away** — for preview roots that rotate / flip
  their contents (e.g. `EB_StepFlip_*`), a naive probe past the host's far
  face may land inside a neighbouring part that isn't the real mate. Use
  the mate as a sanity check only — the `host_name`, `face`, `u`, `v` are
  the values that matter.
- **Pre-existing EB leaf transforms are axis-aligned translations only.**
  The snapping math assumes that; if you add rotated parts, the u/v
  calculation needs to account for the part's rotation.
