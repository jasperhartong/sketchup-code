# Skeleton Dimensions — Release notes (1.0.0 → 1.3.5)

## 1.3.x

### 1.3.5
- **bugfix: ◩ Frame diagonals** — Convex-hull corner selection now finds all four frame corners correctly; both TL–BR and BL–TR diagonals are always drawn.
- **📏 Beam length** — Beam length dimensions now use actual geometry vertices instead of bounding-box corners, measuring the true longest extent along the beam axis (matters for beams with angled cuts).
- **📐 Dimension placement** — Per-beam length dimension is placed on the side of the beam with the longest edge.

### 1.3.4
- **Internal** — Algorithm split into `helpers.rb`, `dimension_cumulative.rb`, and `label.rb` for maintainability; behavior unchanged.

### 1.3.3
- **bugfix: 🧹 Labels** — Re-run no longer stacks labels: the previous “Dimensions: v…” label is removed before adding the new one.

### 1.3.2
- **🔔 Notification** — Success message after adding dimensions (desktop notification when running as the installed extension).

### 1.3.1
- **bugfix: 📐 Diagonals** — Diagonal dimension offset now based on corner distance for more consistent placement.

### 1.3.0
- **🏷️ Version label** — Bottom-right “Dimensions: vX.Y.Z” label with timestamp on the dimension sublayer.
- **📍 Placement** — Improved label and dimension placement.

---

## 1.2.x

- **◩ Frame diagonals** — TL–BR and BL–TR diagonal dimensions with ◩ prefix; correct in-view lengths.
- **📏 Beam length** — More accurate diagonal beam lengths (center-to-center).
- **🛡️ Limit** — Stops after 400 dimensions per run so SketchUp stays responsive (e.g. on large models).

---

## 1.1.0

- No user-facing changes.

---

## 1.0.0 — Initial release

- **📐 Skeleton dimensions** — Select one component instance (frame/skeleton), run from Extensions menu; adds dimensions to beams.
- **📏 Cumulative** — Horizontal cumulative dimensions along vertical beams (right-edge x positions).
- **📐 Per-beam** — Per-beam dimensions for vertical, horizontal, and diagonal members (length along beam).
- **🗑️ Clear** — Clear dimensions (and dimension sublayer contents) for the selected instance.
- **📂 Sublayer** — Dimensions drawn on a dedicated “Maten” sublayer under the instance’s layer.

*(No 1.0.x releases between 1.0.0 and 1.1.0.)*
