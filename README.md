# MenuDock

A minimalist, highly customisable replacement for the macOS Dock that lives entirely in the
menu bar. Add any installed app, give it any icon, group apps into dropdown folders, and
launch or activate them with one click — exactly like a Dock tile.

Swift 6 · SwiftUI (settings) · AppKit (menu bar) · macOS 14+

```bash
make run      # build, then launch from .build (development loop)
make install  # build and install to /Applications, then launch
make stop     # quit
make icon     # redraw Resources/AppIcon.icns
make reset    # delete config + custom icons and start clean
make logs     # tail os_log output
```

The Xcode project is generated from `project.yml`. **Run `make project` (or `xcodegen generate`)
after adding or removing source files** — `MenuDock.xcodeproj` is git-ignored on purpose.

---

## Project structure

```
Sources/MenuDock/
├── App/
│   ├── AppDelegate.swift          @main, accessory activation policy, window ownership
│   ├── AppEnvironment.swift       object graph, built once at launch
│   └── LoginItem.swift            SMAppService launch-at-login
├── Model/                         pure data — all `nonisolated`, all Codable + Sendable
│   ├── AppReference.swift         relocation-tolerant pointer to an installed app
│   ├── IconSpec.swift             appIcon | symbol | custom(file, renderingMode)
│   ├── DockItem.swift             one status item: .application or .group
│   └── Configuration.swift        the on-disk document + schemaVersion
├── Store/
│   ├── ConfigurationStore.swift   @Observable source of truth, debounced atomic writes
│   └── IconLibrary.swift          copies icons in, caches rendered results
├── Services/
│   ├── AppLauncher.swift          launch / activate / hide / quit via NSWorkspace
│   ├── RunningAppsMonitor.swift   push-based running-state tracking
│   └── InstalledAppsIndex.swift   background scan of /Applications for the picker
├── Icons/
│   ├── ImageAnalysis.swift        saturation-based monochrome detection
│   ├── IconRenderer.swift         fit + template + running-dot compositing
│   └── Builtin/
│       ├── Pen.swift              drawing primitives on a 24x24 y-down grid
│       ├── BuiltinIcon.swift      catalogue entry + phase/frame maths
│       ├── StaticIcons.swift      36 category glyphs
│       ├── AnimatedIcons.swift    12 gently animated glyphs
│       └── IconAnimator.swift     one shared timer for every animated item
├── MenuBar/
│   ├── StatusItemCoordinator.swift  reconciles model <-> live NSStatusItems
│   ├── StatusItemController.swift   owns one NSStatusItem, routes clicks
│   ├── MenuBuilder.swift            builds NSMenus from live state
│   └── MenuAction.swift             closure-backed menu items
└── Settings/                      SwiftUI, hosted in a plain NSWindow

Tools/GenerateAppIcon/           draws Resources/AppIcon.icns (`make icon`)
```

---

## The six decisions that shape everything

### 1. One `NSStatusItem` per entry, reconciled by identity — and the list is the order

`StatusItemCoordinator` diffs `configuration.items` against a `[DockItem.ID: StatusItemController]`
map. Renaming an item, changing its icon, or an app launching updates it in place; only genuine
additions, removals and **moves** touch the menu bar itself.

> **macOS constraint:** there is no public API to move a status item, and each newly created one
> is placed to the *left* of that app's existing items. Creation order is the only lever there is.

So the coordinator creates items in reverse, and when the model's order changes it tears the whole
row down and rebuilds it. That sounds heavy-handed; it isn't, because anything that has to move can
only move by being recreated, and it can only be recreated in the right place if everything after
it is too. Deletions are exempt — removing an item never disturbs the relative order of the rest —
and so is every non-structural edit, so the menu bar does not flicker while you type in the
settings window.

There is deliberately **no `autosaveName`**. It persists a position per item, which then outranks
creation order: the list in Settings would say one thing and the menu bar would keep showing
another, permanently. The cost is that ⌘-dragging one of these icons does not survive a relaunch.
The list is the ordering control instead, and what you arrange there is what you get.

*Verified end-to-end: dragging the third row to the top moved the third icon to the leftmost
position, and the order survived a relaunch.*

### 2. SwiftUI does not own the menu bar

`MenuBarExtra` manages exactly one status item. This app's premise is N of them, created and
destroyed at runtime, so the menu bar is AppKit's job. SwiftUI is used where it is strongest —
the settings window's content, hosted in an `NSHostingController`.

The settings window is a plain `NSWindow`, not SwiftUI's `Settings` scene. An `LSUIElement` app
has no application menu, so `Settings` would be unreachable except through a private selector
whose name changed between macOS 13 (`showPreferencesWindow:`) and 14 (`showSettingsWindow:`).

### 3. The status item deliberately has **no** `menu`

Assigning `NSStatusItem.menu` makes AppKit swallow the click to open the menu — the button's
`action` never fires, and left-click-launches becomes impossible.

So the button keeps a plain target/action, widened with
`sendAction(on: [.leftMouseUp, .rightMouseUp])`, and `StatusItemController` decides what each
click means. When a menu genuinely needs to appear:

```swift
statusItem.menu = menu
defer { statusItem.menu = nil }
statusItem.button?.performClick(nil)   // blocks for the duration of menu tracking
```

`NSMenu.popUp(positioning:at:in:)` also works but leaves the button un-highlighted, which reads
as broken next to every system menu extra.

Control-click arrives as a *left*-click with `.control` set, so both are checked.

### 4. One launch path, not "check running then branch"

The obvious implementation is wrong in the case users notice most:

```swift
// Don't do this.
if let running = app.runningInstances.first { running.activate() } else { launch() }
```

An app that is **running with no windows** (Safari with every window closed) gets pulled forward
showing nothing. The real Dock sends a reopen Apple Event (`kAEReopenApplication`), which is what
makes Safari create a window.

`NSWorkspace.openApplication(at:configuration:)` does all of it in one call — launches if closed,
activates if open, unhides if hidden, sends reopen either way — and with
`createsNewApplicationInstance = false` it never spawns a duplicate. Running-state detection is
reserved for what it is actually good for: menu contents and the indicator dot.

*Verified against a real app: closed → launches; backgrounded → activates with the same PID;
hidden → unhides; `openNewInstance()` → second PID; `quit(force:)` → all instances gone.*

### 5. Icons: copy in, analyse, cache

**Storage.** Custom icons are **copied** into `~/Library/Application Support/MenuDock/Icons/`
under a generated name; the config stores only that name. Referencing the original path would
silently break the menu bar when the user cleans out `~/Downloads`.

**Identity.** Apps are keyed by bundle identifier, resolved through three tiers:
LaunchServices → last known path → bookmark. Bundle-ID-first matters more than it looks: seeding
`/Applications/Safari.app` resolves to `/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app`.

**Monochrome adaptation.** The signal is **saturation**, not luminance — a monochrome icon has
near-zero saturation on every pixel, while a two-tone black-and-white *logo* would fool a
luminance test. Pixels are un-premultiplied before measurement (`NSBitmapImageRep` stores
premultiplied alpha, so a 50%-opaque grey otherwise reads as saturated). Under 2% coloured
pixels ⇒ `isTemplate = true`, and AppKit tints it for Light/Dark mode and menu bar transparency
for free.

The heuristic has one honest failure mode: a *greyscale photograph* is colourless but not a
silhouette, and templating flattens it. Hence `RenderingMode` — Automatic / Monochrome / Original
— with the settings pane stating in words what Automatic decided.

**Size is per-icon, but only for custom artwork.** `iconSize` in General sets the size for
everything; a `.custom` spec may carry its own `pointSize` that overrides it. The asymmetry is the
point. Built-in glyphs are drawn on one grid with one stroke weight and an app's own icon is a
square bitmap Apple already balanced, so both are consistent at the global size. A user's logo
might be a wide wordmark or a tight square with no padding, and no single number flatters both.
The ceiling comes from `NSStatusBar.thickness` rather than a constant, so no slider can offer a
size that would be clamped away before it reached the screen.

The settings pane shows the icon at its true size on a menu-bar-coloured strip beside two real
system items. A size control without a true-size readout is unusable — 16pt and 19pt are
indistinguishable in an 88pt well, and the alternative is looking up at the menu bar and back
down again for every step.

**Vector stays vector.** `NSImage` decodes SVG natively into a resolution-independent
`_NSSVGImageRep`. When no compositing is needed the renderer only stamps `size`/`isTemplate` and
hands that representation straight back, so the icon re-renders sharply at any backing scale.
Only the running-dot path rasterises, and it emits explicit 1× and 2× bitmaps.

---

### 6. Built-in icons are drawn, not shipped

48 icons — 36 static category glyphs and 12 animated — defined as code on a 24 × 24 y-down grid
with a shared 1.9-unit stroke system. Drawing them procedurally means they are pixel-exact at any
menu bar height, weigh a few hundred bytes each, and — for the animated ones — can be evaluated at
an arbitrary phase rather than baked into a filmstrip. All are monochrome by construction, so
`isTemplate` is unconditional and they tint with Light/Dark mode for free.

They are **category glyphs, not brand logos**: one "Browser" icon serves Safari, Chrome, Arc and
Firefox. Redrawing third-party marks would be a trademark problem to ship, logos age badly as
companies rebrand, and a coherent single-weight set reads far better in a menu bar than a row of
mismatched logos. Users who want a specific brand mark can still drop in their own SVG.

Animation is deliberately restrained — 2.4–4.5s periods, eased rather than linear, small
amplitude or pure opacity. A menu bar sits in motion-sensitive peripheral vision all day, so
anything sharp there reads as an alert. Motion is suppressed entirely under **Reduce Motion**,
and pauses when the screens sleep.

## Installing, and the app icon

`LSUIElement` keeps MenuDock out of the Dock and ⌘-Tab, but it is still an ordinary application
bundle: installed in `/Applications` it is indexed by Spotlight like anything else
(`kMDItemKind = "Application"`), and launching it while it is already running opens Settings via
`applicationShouldHandleReopen`. `make install` does the copy.

The icon is **drawn** by `Tools/GenerateAppIcon`, for the same reasons the menu bar glyphs are: it
stays editable as geometry, and every `.icns` entry is rendered natively at its own size rather
than downsampled from 1024. The mark is the app — the body is your screen, the white band across
its top is the menu bar, the three punched-out shapes are apps sitting in it, on the right where
real status items live.

It is drawn **full-bleed as a plain square**, which is not how macOS icons were authored for a
decade. macOS 26 supplies the rounded container itself and composites artwork inside it, so the
classic 824-in-1024 inset body renders as a shape nested in a shape — two sets of corners, a band
that stops short of the edges. Rounding the artwork instead of insetting it is no better: any
radius that is not exactly the mask's leaves a dark crescent in each corner. A square has nothing
to misalign. *Confirmed by rendering `NSWorkspace.icon(forFile:)` for this bundle beside
Terminal's and Calculator's at 16–256pt, which is also how the nesting was spotted in the first
place.*

## Performance

Nothing polls. `RunningAppsMonitor` seeds once and then listens to
`didLaunchApplicationNotification` / `didTerminateApplicationNotification`, narrowed to just the
bundle identifiers currently on the menu bar. State reaches the menu bar through `@Observable`
and `withObservationTracking`, so one change triggers exactly one reconcile.

`IconLibrary` caches rendered images keyed on everything that affects output (spec, app, size,
running state, indicator setting, animation frame), so a no-op refresh is a dictionary lookup and
each animation frame is drawn at most once ever.

Measured on this machine:

| State | CPU | RSS |
|---|---|---|
| Static icons only (any number) | **0.0%** | ~45 MB |
| One animated icon @ 12fps | **~1.0–1.5%** | ~45 MB |

Animation is not free, and the cost is almost entirely AppKit recompositing the menu bar on each
`button.image` assignment — not the drawing, which is cached. That is why the tick rate was
measured down from 15fps to 12fps (~2.9% → ~1.5%) and why subscribers skip ticks where the
quantised frame has not changed. Users who want none of it can turn animation off in General.

## Concurrency

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every declaration is main-actor
isolated unless marked `nonisolated`, which for a UI-bound app removes nearly all annotation
noise and makes the genuinely-background paths obvious. The exceptions are all deliberate:

- **Model types** are `nonisolated` — pure data, constructed in bulk by the background app scan.
- **`isolated deinit`** on `StatusItemController`, `RunningAppsMonitor`, and
  `StatusItemCoordinator`, because a plain `deinit` on a main-actor type is itself nonisolated
  and cannot touch `NSStatusItem` or observer tokens.
- **Workspace notification blocks** extract the bundle identifier (a `String`) before hopping to
  the main actor; `Notification` is not `Sendable`.
- **`AppLauncher.log`** is `nonisolated` because `openApplication`'s completion handler is
  `@Sendable`.

## Configuration is treated as the user's data

Two rules, both learned the hard way:

- **Every field decodes with `decodeIfPresent` and a default.** Swift's *synthesized* `Decodable`
  ignores property defaults and throws `keyNotFound` for absent keys, so merely adding a new
  preference invalidates every config file already on disk. Hand-written `init(from:)` makes
  forward field additions a non-event. See the note on `Configuration`.
- **`IconLibrary.pruneOrphans` never deletes.** Unreferenced artwork moves to `Icons/Unused/`.
  It previously called `removeItem`, which combined with the point above into real data loss: a
  config that failed to decode loaded as *empty*, so every icon looked unreferenced and was
  deleted permanently — while the config itself sat safe in a `.corrupt-*` backup beside it.
  `ConfigurationStore.didFailToLoad` now also suppresses pruning after a failed load, but that
  alone would fix one trigger rather than the hazard. User-supplied artwork is not ours to delete.

A quarantined config surfaces a banner in Settings with a button to reveal the preserved file,
rather than silently presenting an empty menu bar.

## Not sandboxed

Launching arbitrary applications and scanning `/Applications` are awkward under App Sandbox, so
the app is intended for distribution outside the Mac App Store. For Developer ID + notarisation,
set a signing identity and `ENABLE_HARDENED_RUNTIME = YES` in `project.yml`.
