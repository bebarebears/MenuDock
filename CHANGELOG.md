# Changelog

All notable changes to MenuDock are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Clipboard items** — a searchable history of what you copy, in the menu bar. Records text
  (with RTF alongside it, so one row pastes formatted into Pages and plain into a terminal),
  images, and files. Click the icon or press ⌘⇧V to drop the history from it; arrow through it and
  press Return, use ⌘1–⌘9, or hold ⌘⇧ and tap V to walk the list and release to paste — the ⌘-Tab
  gesture. Retention (1 hour to forever), an item ceiling, and per-type capture toggles are all in
  Settings, alongside the icon picker every other item has.
  Copied files are stored by path and never duplicated; images are stored once as PNG with a
  thumbnail. Items apps mark `org.nspasteboard.ConcealedType` — what password managers set — are
  skipped by default, as are transient ones. Nothing is polled at all unless a Clipboard item is
  in the menu bar.
  Opening, searching, cycling and copying need no permission; only pasting *for* you does, since
  macOS gates synthesised keystrokes behind Accessibility. Without it, choosing an item copies it
  and returns you to your app.
- A `clipboard` built-in glyph, bringing the set to 107.
- MenuDock now explains a refused auto-paste instead of doing nothing visible. macOS ties an
  Accessibility grant to the exact copy of the app it was given to, so rebuilding or updating
  MenuDock invalidates it *while System Settings still shows the switch as on* — and the usual
  remedy is a no-op, because macOS only raises its permission prompt when it has no entry for the
  app at all. The first refused paste of a launch now says what has happened and offers System
  Settings, the Recall pane distinguishes "never granted" from "granted to an earlier build" and
  reflects the live state rather than a stale snapshot, and `make signing-identity` creates a
  stable self-signed certificate so local rebuilds stop revoking the permission at all.
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
- Activity and Clipboard items are limited to one each. The + menu shows the row ticked off
  rather than hiding it, the store refuses a second, and a configuration file that somehow
  contains two — hand-edited, or merged between Macs — keeps the leftmost on load.
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
