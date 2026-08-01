# Changelog

All notable changes to MenuDock are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Activity items** — a live system readout in the menu bar, alongside apps, folders and groups.
  Shows CPU, GPU, power draw in watts, memory, network up/down and disk read/write; each is a graph,
  bar, ring or number, with an optional caption, and the item sizes itself to fit whatever is
  configured. Clicking it lists every reading in full and offers Activity Monitor; those readings
  keep updating while the menu is open, on a fixed column so the menu cannot resize under the
  cursor.
  Counters are read directly from the kernel (`host_statistics`, `getifaddrs`, IOKit) rather than
  by shelling out, only the metrics actually on screen are sampled, and sampling stops when the
  menu bar is hidden, locked or asleep. A default item costs ~0.18% of one core.
  Power is SoC package power (CPU + GPU + ANE) from Apple Silicon's IOReport energy
  accumulators — the counters `powermetrics` reads — and excludes display, SSD and peripherals.
- `make activity-sheet`, which redraws `docs/images/activity-styles.png` from the renderer itself.
- Universal (Apple Silicon + Intel) Release builds, packaged as a `.dmg`.
- GitHub Actions workflows for CI and tag-driven releases.
- Homebrew cask, installable from `bebarebears/tap`.

### Changed
- Screen sleep, fast user switching, lock state and Low Power Mode are now tracked once, by
  `DisplayActivityMonitor`, and shared by the icon animator and the metrics sampler instead of
  being observed separately by each.
- Bundle identifier is now `com.bebarebears.MenuDock`. Existing settings in
  `~/Library/Application Support/MenuDock` are unaffected, but launch-at-login has to be
  re-enabled once after upgrading, because macOS tracks login items by bundle identifier.

## [0.1.0]

First public release.

- Pin any installed app or folder to the menu bar; click to launch, activate or open.
- 106 built-in icons — 78 static, 28 animated — drawn in code rather than shipped as assets.
- Custom PNG and SVG icons, SF Symbols, and per-item size overrides.
- Groups: several apps behind one icon, as a dropdown menu.
- Running-state indicator dot, with hide/quit/new-window in the right-click menu.
- Launch at login via `SMAppService`.
- Motion suppressed under Reduce Motion; animation pauses on sleep, lock and occlusion.
