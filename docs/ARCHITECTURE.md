# MenuDock architecture

How MenuDock is put together, and why. For installing and using it see the
[README](../README.md); for getting set up to work on it see
[CONTRIBUTING](../CONTRIBUTING.md).

Swift 6 · SwiftUI (settings) · AppKit (menu bar) · macOS 14+ · no third-party dependencies

This document exists because most of the surprising code in this project is surprising for a
reason — a macOS API constraint, a measurement, or a bug that cost real user data. Those reasons
are recorded here rather than in comments, so that a future change can tell a deliberate
constraint from an oversight.

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
│   ├── FolderReference.swift      relocation-tolerant pointer to a folder
│   ├── IconSpec.swift             appIcon | symbol | builtin | custom(file, renderingMode)
│   ├── ActivityEntry.swift        gauges: metric x style x caption, + refresh interval
│   ├── DockItem.swift             one status item: .application, .group, .folder or .activity
│   └── Configuration.swift        the on-disk document + schemaVersion
├── Store/
│   ├── ConfigurationStore.swift   @Observable source of truth, debounced atomic writes
│   └── IconLibrary.swift          copies icons in, caches rendered results
├── Services/
│   ├── AppLauncher.swift          launch / activate / hide / quit via NSWorkspace
│   ├── RunningAppsMonitor.swift   push-based running-state tracking
│   ├── InstalledAppsIndex.swift   background scan of /Applications for the picker
│   ├── SystemMetrics.swift        kernel counters: CPU, memory, GPU, network, disk
│   ├── MetricsMonitor.swift       one timer, demand-gated samplers, history windows
│   └── DisplayActivityMonitor.swift  can anyone see the menu bar? (shared by both timers)
├── Icons/
│   ├── ImageAnalysis.swift        saturation-based monochrome detection
│   ├── BitmapCompositor.swift     multi-scale bitmap packing, shared by both renderers
│   ├── ActivityRenderer.swift     draws gauge strips and computes their width
│   ├── IconRenderer.swift         fit + template + running-dot compositing
│   └── Builtin/
│       ├── Pen.swift              drawing primitives on a 24x24 y-down grid
│       ├── BuiltinIcon.swift      catalogue entry + phase/frame maths + frame cache
│       ├── StaticIcons.swift      78 category glyphs
│       ├── AnimatedIcons.swift    28 gently animated glyphs
│       └── IconAnimator.swift     one shared timer for every animated item
├── MenuBar/
│   ├── StatusItemCoordinator.swift  reconciles model <-> live NSStatusItems
│   ├── StatusItemController.swift   owns one NSStatusItem, routes clicks
│   ├── GlyphLayer.swift             animates without redrawing the status item
│   ├── MenuBuilder.swift            builds NSMenus from live state
│   └── MenuAction.swift             closure-backed menu items
└── Settings/                      SwiftUI, hosted in a plain NSWindow
    ├── AddItemPopup.swift         the + menu, drawn inside the window
    └── ActivityEditor.swift       gauge list + a preview that is the real renderer

Tools/GenerateAppIcon/           draws Resources/AppIcon.icns (`make icon`)
Tools/RenderActivity/            draws docs/images/activity-styles.png (`make activity-sheet`)
```

---

## The eight decisions that shape everything

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

**Size is per item, for every kind of icon.** `iconSize` in General sets the default; any item may
carry its own `iconSize` that overrides it, whatever its icon source is.

The override lives on the **item**, not on the icon spec — where it used to live, as a `pointSize`
inside `.custom`. Two reasons. It describes this slot in the menu bar rather than the artwork, so
nudging Finder up to 20pt should survive swapping the glyph underneath it; and a size knob that
only appears for custom images is a knob users cannot find. Configurations written by the old
version are migrated on decode: `DockItem.init(from:)` lifts a legacy `pointSize` onto the item and
strips it from the spec, so there is exactly one source of truth afterwards and nobody's chosen
size is lost in the upgrade.

The ceiling comes from `NSStatusBar.thickness` rather than a constant, so no slider can offer a
size that would be clamped away before it reached the screen. Clamping happens in
`DockItem.resolvedIconSize(default:)` and *not* inside `IconLibrary`, which takes the size it is
given — the settings pane's 48pt preview well is a legitimate caller, and clamping it to the menu
bar's 22pt ceiling was quietly upscaling a small render into a large well.

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

106 icons — 78 static category glyphs and 28 animated — defined as code on a 24 × 24 y-down grid
with a shared 1.9-unit stroke system. Drawing them procedurally means they are pixel-exact at any
menu bar height, weigh a few hundred bytes each, and — for the animated ones — can be evaluated at
an arbitrary phase rather than baked into a filmstrip. All are monochrome by construction, so
`isTemplate` is unconditional and they tint with Light/Dark mode for free.

A whole category is "Files & Folders", added for folder items and leaning towards *places* rather
than more folders: a second folder-shaped glyph says nothing about which folder it points at.

Drawing a glyph blind and shipping it is how you get a flame that reads as a water droplet — which
is exactly what the first attempt was. Every glyph here was rendered to a contact sheet and looked
at, at both 46pt and 18pt, and several were rebuilt on the evidence: a solid cloud that overpowered
every outlined neighbour, a bell whose two same-height control points gave it the flat top of a
cloche, and a USB stick that turned out to be the battery silhouette with the nub on the other side.

They are **category glyphs, not brand logos**: one "Browser" icon serves Safari, Chrome, Arc and
Firefox. Redrawing third-party marks would be a trademark problem to ship, logos age badly as
companies rebrand, and a coherent single-weight set reads far better in a menu bar than a row of
mismatched logos. Users who want a specific brand mark can still drop in their own SVG.

Animation is deliberately restrained — 2.2–4.5s periods, eased rather than linear, small
amplitude or pure opacity. A menu bar sits in motion-sensitive peripheral vision all day, so
anything sharp there reads as an alert.

![Six animated glyphs sampled across one loop](images/icons-motion.png)

*One loop of six glyphs, sampled left to right — the whole amplitude of the motion is visible
here, which is the point. Regenerate with `make showcase`.* Motion is suppressed entirely under **Reduce Motion**, and
pauses when the screens sleep, when the screen locks, when the session is switched away, and when
every animated icon is occluded — which is what happens the moment a fullscreen app hides the menu
bar. Low Power Mode halves the frame rate and says so in Settings.

Four glyphs also **react to a click** — the dog, the cat, the ghost, the bell. They receive a phase
in the 1…2 range for the duration of a one-shot reaction and return to their idle loop afterwards;
`StatusItemController` drives that range directly from wall-clock time.

---

### 7. Folders are items, not a special case

A folder item is a third `DockItem.Kind` beside `.application` and `.group`, holding one or more
`FolderReference`s. One folder: a click opens it in Finder, no menu, same as an app item launching.
Several: the click lists them, unless "Open every folder on click" is on. `NSWorkspace.open(_:)`
rather than `activateFileViewerSelecting(_:)` — the latter is the *reveal* gesture, which would open
the folder's parent with it highlighted, so clicking "Documents" would land you in your home folder.

Folders resolve through two tiers, not the three an app gets: there is no bundle identifier for a
folder, so it is last-known-path (a single `stat`, correct almost always) then bookmark data (which
survives the rename or move a path cannot). A folder on an unmounted volume gets an alert that names
that possibility, because an unplugged drive is not a broken setup and should not read like one.

The rows in a folder's left-click menu carry **no submenu**, and that is load-bearing: AppKit never
sends a menu item's action when the item has a submenu — it opens the submenu instead — so attaching
per-folder extras there would have silently made every row do nothing. Those extras live in the
right-click menu, where a row is a heading rather than the one action the menu exists for.

### 8. Activity items pay only for what is on screen

An Activity item is the fourth `DockItem.Kind`, and the first one whose appearance is *generated*
rather than chosen: there is no `IconSpec` behind it, so `Kind.icon` reports a stand-in symbol and
ignores writes, and the two surfaces that draw the real thing call `ActivityRenderer` directly.

Three things make it affordable enough to sit in a menu bar all day.

**Counters, not subprocesses.** CPU comes from `host_statistics(HOST_CPU_LOAD_INFO)` — the
aggregate call, not `host_processor_info`, which allocates a per-core array the caller has to
`vm_deallocate` — memory from `host_statistics64`, network from `getifaddrs`, and GPU and disk from
IORegistry properties on service handles that are looked up once and held. Shelling out to `top` or
`ioreg` once a second is how this feature is usually written and it is two to four orders of
magnitude more expensive than the `mach_msg` it wraps. All five samplers together are ~0.39 ms.

**Demand gating.** `MetricsMonitor` unions every subscriber's metrics and creates only those
samplers; dropping the last GPU gauge releases the GPU's registry handle and its history. This is
most of the win, because GPU, network and disk are ~90% of the per-tick cost, and the common case
is a CPU-and-memory item that touches none of them. It is why one default item costs 0.18% of a
core and one with six metrics costs 0.38%.

**Nothing observable.** Samples deliberately do *not* land in state `StatusItemCoordinator`
observes. If they did, every tick would trigger a full menu bar reconcile. Subscribers get an
explicit callback and pull what they need; the single `@Observable` property is `generation`, which
exists so the settings preview can redraw and which the coordinator never reads.

Screen sleep, user switching, lock state and Low Power Mode moved out of `IconAnimator` into
`DisplayActivityMonitor` when the second timer arrived, so the two cannot disagree about whether
anyone can see the menu bar.

The one non-obvious rule in the renderer is that **width never depends on the current value**. A
numeric gauge is measured from the widest string its metric can produce, which is why
`ActivityMetric.compactString` goes to the trouble of guaranteeing four characters — including
rounding *before* choosing the unit, since formatting 9,999,999 B/s by magnitude first yields
`10.0M` and overflows a cell measured for four. A status item that changes width once a second
drags every icon to its left along with it.

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
running state, indicator setting), so a no-op refresh is a dictionary lookup. Animated built-ins
have their own cache — a per-icon strip of frames indexed by frame number, in `BuiltinIconCatalog`
— so a loop is rasterised at most once ever and shared by the menu bar, the icon gallery and the
preview well. Steady-state animation does no drawing at all.

### The expensive part was not the drawing

With frames cached, animating still cost **7.5% of a core for a single 12fps icon**. A `sample` of
the process says why, and it is not compositing:

```
-[NSStatusBarButton setImage:]
  └ -[NSStatusBarButtonCell drawWithFrame:inView:]
     └ -[NSSystemStatusBar drawBackgroundInRect:inView:highlight:]
        └ -[NSSceneStatusItem _setSelectedContentFrame:options:]
           └ +[CAFenceHandle newFenceFromDefaultServer]
              └ mach_msg          ← synchronous round trip to the window server, per frame
```

Assigning `button.image` invalidates the button; the button's redraw pushes a new selected-content
frame into the status item's *scene* and fences with the window server to do it. Roughly 6 ms of
that, twelve times a second, to re-measure an icon whose size never changed.

`GlyphLayer` sidesteps it. Animated glyphs are presented as a tinted `CALayer` masked by the frame's
alpha, sitting above the button; setting `contents` hands a finished image to the compositor and the
view never redraws. Static icons keep going through `button.image`, where the cost is paid once and
AppKit's template rendering is exact.

Measured on the development machine (Debug build, two displays, 12fps, CPU time sampled over 15s):

| State | `button.image =` | `GlyphLayer` | RSS |
|---|---|---|---|
| Static icons only (any number) | 0.0% | **0.0%** | ~45 MB |
| Animation turned off in General | 0.0% | **0.0%** | ~43 MB |
| 1 animated icon @ 12fps | 7.5% | **0.6%** | ~41 MB |
| 2 animated icons @ 12fps | 10.9% | — | ~46 MB |
| 4 animated icons @ 12fps | 16.0% | **0.8%** | ~51 MB |

Three things were tried before this and are recorded so nobody repeats them: swapping the
representations inside one reused `NSImage` (7.5%), `isBordered = false` to skip the background draw
(8.0%), and a fixed `statusItem.length` instead of `variableLength` (7.7%). The fence is in the view
redraw itself, so the only fix is not redrawing the view.

The tradeoff is that template rendering becomes ours: the tint is `labelColor` resolved in the
*button's* appearance, swapped for the menu-selection colour while the item's menu is open. What is
given up is the last few percent of AppKit's vibrancy blend against the wallpaper behind a
translucent menu bar — a fair price for 14×, and paid only by animated glyphs.

Everything else is about not running at all: one shared timer rather than one per item; subscribers
that skip ticks where the quantised frame has not changed; and the timer stopping outright when the
screens sleep, the screen locks, the session is switched away, or every animated item is occluded.
Users who want none of it can turn animation off in General, which costs exactly 0.0%.

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
- **`IconAnimator` observes notifications with a `Sendable` value, not a closure.** The observer
  block runs outside the main actor, so a `{ $0.screensAsleep = true }` handler is a data race the
  compiler is right to reject. An `Effect` enum crosses instead and is switched on inside the
  main-actor hop.
- **Icon drawing closures are main-actor by inheritance; nested `func`s inside them are not.** A
  closure literal formed in `@MainActor` context inherits that isolation, which is why every glyph
  can call `pen.disc(...)` directly — but a local function declared inside one cannot. Helpers that
  touch the pen are therefore closures (`let star = { ... }`), not nested functions.

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
