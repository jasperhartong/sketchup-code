# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.3.5]

### Fixed
- **Frame diagonals** — Convex-hull corner selection now finds all four frame corners correctly; both TL–BR and BL–TR diagonals are always drawn.

### Changed
- **Beam length** — Beam length dimensions now use actual geometry vertices instead of bounding-box corners, measuring the true longest extent along the beam axis (matters for beams with angled cuts).
- **Dimension placement** — Per-beam length dimension is placed on the side of the beam with the longest edge.

## [1.3.4]

### Changed
- Algorithm split into `helpers.rb`, `dimension_cumulative.rb`, and `label.rb` for maintainability; behavior unchanged.

## [1.3.3]

### Fixed
- **Labels** — Re-run no longer stacks labels: the previous "Dimensions: v…" label is removed before adding the new one.

## [1.3.2]

### Added
- **Notification** — Success message after adding dimensions (desktop notification when running as the installed extension).

## [1.3.1]

### Fixed
- **Diagonals** — Diagonal dimension offset now based on corner distance for more consistent placement.

## [1.3.0]

### Added
- **Version label** — Bottom-right "Dimensions: vX.Y.Z" label with timestamp on the dimension sublayer.

### Changed
- **Placement** — Improved label and dimension placement.

## [1.2.0]

### Added
- **Frame diagonals** — TL–BR and BL–TR diagonal dimensions with correct in-view lengths.
- **Dimension limit** — Stops after 400 dimensions per run so SketchUp stays responsive on large models.

### Changed
- **Beam length** — More accurate diagonal beam lengths (center-to-center).

## [1.1.0]

No user-facing changes.

## [1.0.0]

### Added
- **Skeleton dimensions** — Select one component instance (frame/skeleton), run from Extensions menu; adds dimensions to beams.
- **Cumulative dimensions** — Horizontal cumulative dimensions along vertical beams (right-edge x positions).
- **Per-beam dimensions** — Per-beam dimensions for vertical, horizontal, and diagonal members (length along beam).
- **Clear** — Clear dimensions (and dimension sublayer contents) for the selected instance.
- **Sublayer** — Dimensions drawn on a dedicated "Maten" sublayer under the instance's layer.
