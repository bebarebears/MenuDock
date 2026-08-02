# Changelog

All notable changes to MenuDock are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1]

### Changed
- The Accessibility note under *Paste straight into the app I was using* no longer repeats what the
  toggle's own `?` says. Explaining why macOS requires the permission twice, once above the other,
  buried the only line that is news — that until it is granted, the feature you have just switched
  on is doing half its job.
- Reshot `docs/images/settings.png`, which still showed the paragraph under *Name* that moved
  behind a `?` in 0.3.0, and so advertised a pane the app no longer has.

## [0.3.0]

### Added
- **A fresh install is no longer an empty menu bar.** MenuDock has no Dock icon and no window, so
  an empty first launch was indistinguishable from an app that failed to start — and an empty item
  list cannot answer the question that actually matters, which is not "how do I add an app" but
  "what can this thing be". A new configuration now arrives as a worked example: every installed
  app, the clipboard history, a group of the stock Mac apps, Safari, System Settings, and CPU and
  memory as load-coloured rings. Every app in it is resolved through LaunchServices first and
  anything missing is left out, so nobody gets a broken icon, and the whole set is removable in a
  click. Only a configuration file that is genuinely *absent* is seeded — a file that fails to
  decode is quarantined and starts empty exactly as before, because replacing a user's menu bar
  with a stranger's would read as MenuDock having thrown theirs away.
- **Profiles** — named subsets of the menu bar you switch between: Work, Personal, Presenting.
  Switch from any item's menu or from the picker above the item list in Settings.
  A profile is a *membership label*, not a second menu bar: there is still one list of items in one
  order, and a profile decides which of them appear. An app in two profiles is one entry with one
  icon, one name and one size, and the menu bar's identity diffing keeps working, so a profile
  switch updates the items that changed rather than tearing down the whole row. A new profile
  starts with every item in it, and an item that has never been assigned belongs to all of them —
  so adding profiles to an existing setup changes nothing until you say what to leave out.
- **Auto-hiding when the menu bar runs short.** A 14" MacBook has roughly a third the usable bar of
  a large display once the notch and the app menus have taken their share, so a setup that fits
  docked may not fit undocked — and macOS does not clip gracefully: items that do not fit are
  silently not drawn, starting from the left. Each item now carries a priority (*Always show*,
  *Normal*, *Hide first*) and MenuDock drops the low ones until the rest fit, restoring them when
  the room comes back. Settings states the arithmetic behind the decision, hidden items stay in the
  list dimmed rather than vanishing from it, and the whole thing is off by default because an icon
  disappearing unasked reads as a crash.
  The usable region is read from `NSScreen.auxiliaryTopRightArea` on a notched Mac and estimated
  elsewhere; what other apps have taken is measured off the live window frames. What MenuDock wants
  is computed from the model rather than measured, which is what stops the decision from depending
  on its own outcome and oscillating.
- **Four more things an Activity item can show.**
  - **Battery** — charge level, with charging state and time remaining spelled out in the menu.
    Read through `IOPowerSources`, so the estimate is macOS's own rather than one reinvented from
    the current draw. Machines with no internal battery report nothing rather than 100%.
  - **Thermal pressure** — `ProcessInfo.thermalState`, four-valued: Nominal, Fair, Serious,
    Critical. Deliberately not a temperature in degrees: there is no unprivileged, documented way
    to read one on Apple Silicon, and this answers the more useful question anyway — how much the
    system is holding back because of heat.
  - **Disk free** — space left on the startup volume, as a level rather than a rate, with the
    figure in gigabytes in the menu. Uses the important-usage capacity Finder reports, and is
    re-read every twenty seconds rather than every tick.
  - **The three processes using the most CPU**, in the click-through menu. Sampled *only while that
    menu is open*: answering it costs a `proc_pid_rusage` per process on the machine — measured at
    ~4 ms, more than every other sampler put together — which would be absurd to pay once a second
    for a menu that is open a few seconds a day.
- **Gauges can colour themselves from the reading** — green when quiet, amber when busy, red when
  it matters — with thresholds set per metric, because one rule is wrong for all of them. Battery
  and free space are inverted, so they redden at the bottom of their range. Settings names the
  exact figures for the metric being edited.
  A coloured gauge cannot be a template image, so the whole strip stops being one and is redrawn
  when the system appearance changes; monochrome gauges sharing it are given the colour AppKit
  would have supplied. Off by default for that reason.
- **A colour for any item's icon.** Ten palette colours plus a full picker, per item, alongside the
  existing per-item size. Every colour is pulled to the middle of the luminance range so one value
  reads on a light menu bar and a dark one. Artwork that already carries colour — an app's own
  icon, a full-colour logo — is left alone, and Settings says so instead of offering a control that
  would do nothing. Animated glyphs are tinted by the layer that already draws them, so a coloured
  animated icon costs exactly what an uncoloured one does.

### Changed
- **The explanatory prose in Settings moved behind a `?`.** Several settings genuinely need a
  paragraph — what the auto-hide rule does, why the clipboard hotkey behaves like ⌘-Tab, where the
  history is stored — and printed inline those paragraphs were the *majority* of every pane: a grey
  wall between one control and the next that a returning user reads exactly never, and that pushed
  the control they came for below the fold. A `?` beside the heading (or beside the one control it
  describes) inverts that cost: one click the first time, invisible every time after. It is a
  button rather than a tooltip because `.help()` needs a hover nobody has a reason to try, offers
  no hint that anything is there, and cannot be reached from the keyboard.
  Only static explanation moved. Anything reporting *state* — a missing Accessibility permission, a
  hotkey another app has claimed, the arithmetic behind an auto-hide decision, the thresholds for
  the metric being edited — stays on the pane, because a user cannot click a button they have no
  reason to suspect is relevant.
- **Adding a metric to an Activity item now shows every metric at once**, with a symbol and a line
  saying what it measures, instead of adding whichever was next and leaving you to change it with a
  popup in the row. The old behaviour made the *set* of available metrics invisible: a user who did
  not already know MenuDock could show disk write had no way to find out except by cycling until it
  appeared.
- The gauge list reads as a list — metric, and a summary of how it is drawn — with style, caption
  and colour edited below it for whichever row is selected. Four unlabelled popups repeated down
  the page fitted, barely, and read as a spreadsheet.
- `ActivityMetric.widestCompactString` became `widestCompactStrings`. The level unit prints *words*
  rather than figures, and words are not monospaced — `Fair` and `Crit` are the same four
  characters and not the same width — so sizing a numeric gauge means measuring every string the
  metric can produce rather than looking one up.
- `docs/images/activity-styles.png` is gone from the README and from the repository. Sixteen rows
  across two appearances and three sizes is a 5,400-pixel-wide sheet, and at the 860 px a README
  gives it every gauge in it was illegible — it read as a grey smear where a figure should be.
  `make activity-sheet` still draws it for anyone who wants to look at it full size.

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
