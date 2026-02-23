# Changelog — SketchUp Bridge

All notable changes to this plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.5.2] — 2026-02-23

### Added
- **Screenshot helper** — `utils.rb` with `take_screenshot` for programmatic screenshots from command scripts.

### Changed
- Bridge outputs (result.txt, screenshots) moved to `sketchup_bridge/results/`.

## [1.5.1] — 2026-02-22

### Fixed
- Cleanup and packaging improvements.

## [1.5.0] — 2026-02-20

### Changed
- Streamlined debug port functionality; removed deprecated methods.
- Improved UI status reporting.

### Added
- AppObserver registration for better application lifecycle management.

## [1.3.0] — 2026-02-20

### Added
- **Debug port** — Methods for setting and checking the Ruby debug port.
- **UI commands** — Menu items for debug port interaction.
- Improved status reporting to include debug port status.

## [1.1.0] — 2026-02-20

### Added
- **AppObserver** — Timer cleanup on SketchUp quit.

## [1.0.0] — 2026-02-20

### Added
- **File-based command bridge** — Polls `command.rb` and writes results to `result.txt`, letting external tools (e.g. Cursor) run code inside SketchUp.
- **Menu integration** — Start/Stop listener, Set Bridge Directory via Extensions menu.
- **Persistent settings** — Bridge directory saved across sessions.
