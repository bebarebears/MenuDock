# Changelog

All notable changes to MenuDock are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0]

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
- The clipboard dropdown no longer carries a permanent hint strip along its bottom edge. Return,
  ⌘⌫ and Escape are what every list on the platform already uses, and the item count answered a
  question nobody asked; a panel meant to be read in a second was spending a fifth of its height
  on a legend. The hold-⌘⇧-and-tap-V hints remain, shown only during a hold, which is the one
  moment they are neither guessable nor ignorable.
- The clipboard dropdown appears and dismisses instantly, like a menu, instead of fading.

### Fixed
- **The clipboard dropdown could climb above the top of the screen and stay there**, taking its
  search field with it. Its SwiftUI content was pinned to the window with required constraints, so
  the list's own ideal height — every row, not the seven that fit — could win the argument with the
  window's height and Auto Layout would resize the window to settle it. AppKit windows grow from
  their bottom-left origin, so the extra height went straight up through the menu bar. Two things
  then made it permanent: resizes were computed from the panel's current frame, adopting the bad
  top edge as truth, and AppKit's own frame-constraining was free to move the panel afterwards.
  The panel is now sized by its window and never the reverse, every frame is derived from the menu
  bar anchor rather than from the previous frame, and the top edge is clamped to the screen — so a
  displacement from any cause now survives exactly until the next keystroke.
- **The search field only accepted typing the first time the dropdown was ever opened.** The panel
  is built once and reused, so the `onAppear` that focused the field fired once in the life of the
  app; every open after that landed on a window whose first responder was whatever had been left
  behind. It is now focused on every presentation.
- **Typing a search left the selection on an arbitrary row** rather than on the top match, so the
  obvious gesture — type a few letters, press Return — pasted the wrong item. A new query now
  selects its best match.
- **Moving the mouse over the list made it scroll on its own.** Hovering a row selected it,
  selecting a row scrolled it to centre, and scrolling slid a different row under a cursor that had
  not moved — which selected *that*, and the list crawled until it hit an end. Hover no longer
  scrolls, and it is ignored entirely unless the pointer has actually moved, so rows arriving under
  a resting cursor (while the wheel scrolls, while the arrow keys scroll, while a search
  re-filters) no longer overrule the keyboard. The wheel and the scrollbar are what scroll the
  list.
- **⌘⇧V raised the Settings window over the app being pasted into** whenever Settings was open.
  Activating an app raises all of its windows and AppKit offers no way to opt one out, so the raise
  is now undone for windows that were behind another app to begin with. Pressing the shortcut while
  actually working in Settings leaves it alone — and no longer aims the paste at some app
  remembered from earlier, which is why it appeared to do nothing at all.
- A capture landing while the dropdown is open no longer shifts the selection onto a different
  item. The selection follows the item, not the row number.

## [0.1.0]

First public release.

- Pin any installed app or folder to the menu bar; click to launch, activate or open.
- 106 built-in icons — 78 static, 28 animated — drawn in code rather than shipped as assets.
- Custom PNG and SVG icons, SF Symbols, and per-item size overrides.
- Groups: several apps behind one icon, as a dropdown menu.
- Running-state indicator dot, with hide/quit/new-window in the right-click menu.
- Launch at login via `SMAppService`.
- Motion suppressed under Reduce Motion; animation pauses on sleep, lock and occlusion.
