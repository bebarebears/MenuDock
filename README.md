<div align="center">

<img src="docs/images/icon.png" width="128" alt="MenuDock icon">

# MenuDock

**Your Dock, in the menu bar.**

Pin any app or folder to the macOS menu bar. Click to launch, activate or open —
exactly like a Dock tile, without the Dock.

[![Download](https://img.shields.io/github/v/release/bebarebears/MenuDock?label=download&style=for-the-badge)](https://github.com/bebarebears/MenuDock/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?style=for-the-badge&logo=apple)](https://github.com/bebarebears/MenuDock/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)](LICENSE)

<br>

<img src="docs/images/menu-bar-detail.png" width="520" alt="Seven MenuDock icons in the macOS menu bar">

<sub>Apps, a folder and a group — one click from launching.</sub>

</div>

---

## Install

**Homebrew** — recommended, nothing else to do:

```bash
brew install --cask --no-quarantine bebarebears/tap/menudock
```

**Or download it.** Grab `MenuDock.dmg` from the
[latest release](https://github.com/bebarebears/MenuDock/releases/latest), open it, and drag
MenuDock to Applications.

MenuDock has no Dock icon and no window at startup — after launching, **look in your menu bar**.
Click the MenuDock icon and choose *Settings…* to add your first app.

### "Apple could not verify MenuDock"

If you downloaded the DMG rather than using Homebrew, macOS will block the first launch. MenuDock
is free and open source, and is not signed with a $99/year Apple Developer certificate — so macOS
cannot check who built it. The source for every release is in this repository.

To open it anyway:

1. Double-click MenuDock. Click **Done** on the warning.
2. Open **System Settings › Privacy & Security**.
3. Scroll to the bottom — *"MenuDock was blocked to protect your Mac"* — and click **Open Anyway**.
4. Confirm with Touch ID or your password.

You only do this once. If you prefer a single command instead:

```bash
xattr -dr com.apple.quarantine /Applications/MenuDock.app
```

**Requirements:** macOS 14 Sonoma or later, Apple Silicon or Intel.

---

## What you can do

**Add anything.** Any installed app, or any folder — a folder item opens straight in Finder.

**One click to launch.** Click launches if the app is closed, brings it forward if it is open, and
restores a window if it is running with none — the same behaviour as a real Dock tile. A dot marks
what is running. Right-click for hide, quit and new-window.

**Group things.** Put several apps behind one icon and they become a dropdown menu.

<div align="center">
  <img src="docs/images/menu-bar.png" width="880" alt="A full macOS menu bar, with seven MenuDock items sitting between the app menus and the system status items">
  <br>
  <sub>The whole menu bar. Your items sit among the system ones and behave like they belong there —
  and because they are template images, they take the bar's own tint.</sub>
</div>

### Watch your machine, without watching Activity Monitor

An **Activity** item is a live readout of the system: CPU, GPU, memory, network up and down, and
disk read and write. Put as many metrics as you like behind one icon, pick how each one is drawn —
**graph**, **bar**, **ring** or **number** — and caption them with nothing, a letter, or a word.
The item sizes itself to whatever you chose; you never set a width.

<div align="center">
  <img src="docs/images/activity-styles.png" width="880" alt="Every Activity gauge style rendered on a light and a dark menu bar at three sizes">
  <br>
  <sub>Every style, at 16 / 18 / 22 pt, in Light and Dark. Drawn as template images like everything
  else, so they take the menu bar's tint too.</sub>
</div>

Clicking one lists every reading in full — `11.9 MB/s` rather than the four characters that fit in
the bar — and opens Activity Monitor if you want the rest.

**It costs almost nothing.** Everything is read straight from the kernel; nothing shells out to
`top` or `ioreg`. Only the metrics you actually display are sampled, so a CPU-only item never
touches the GPU or the network. Measured on an M5, Release build, sampling once a second:

| Setup | CPU |
|---|---|
| No Activity item | 0.008% of one core |
| One item, CPU graph + memory bar | **0.18%** |
| Two items, 8 gauges across 6 metrics | **0.38%** |

Sampling stops completely when the menu bar is hidden by a fullscreen app, when the screen locks
or sleeps, and when the session is switched away — and the interval doubles in Low Power Mode.

### 106 built-in icons, drawn rather than shipped

Every glyph is **drawn in code** on a 24 × 24 grid, so it is pixel-exact at any menu bar height,
weighs a few hundred bytes, and tints itself for Light and Dark mode automatically.

<div align="center">
  <img src="docs/images/icons-static.png" width="880" alt="All 78 static built-in glyphs">
  <br>
  <sub>78 static glyphs, across 12 categories.</sub>
</div>

Another 28 are **gently animated** — and gently is the point. Periods run 2.2–4.5 seconds, eased
rather than linear, small amplitude or pure opacity. A menu bar sits in your peripheral vision all
day, so anything sharp there reads as an alert.

<div align="center">
  <img src="docs/images/icons-animated.gif" width="880" alt="All 28 animated built-in glyphs, looping">
  <br>
  <sub>28 animated glyphs. Four of them — the dog, the cat, the ghost, the bell — also react when clicked.</sub>
</div>

Prefer your own? Point any item at an SF Symbol, a PNG, or an SVG that stays vector all the way
to the screen.

### Everything is per item

<div align="center">
  <img src="docs/images/settings.png" width="900" alt="The MenuDock settings window, showing the item list and the built-in icon gallery">
</div>

Pick an icon source, override the size for that one item, reorder by dragging — the menu bar
follows the list. The size control previews at **true size** against real system items, because
16pt and 19pt are indistinguishable in a large preview well.

**It stays out of the way.** Animation is suppressed entirely under Reduce Motion, pauses when
your screen sleeps or locks, and halves its frame rate in Low Power Mode. Steady-state CPU use is
under 1%, and turning animation off costs exactly 0.0%.

Your setup lives in `~/Library/Application Support/MenuDock/`. Custom icons are **copied** in, so
cleaning out `~/Downloads` never breaks your menu bar.

---

## Uninstall

```bash
brew uninstall --cask menudock
```

Or drag `/Applications/MenuDock.app` to the Trash. Either way your settings stay in
`~/Library/Application Support/MenuDock/`; delete that folder to remove them too.

---

## Build from source

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
git clone https://github.com/bebarebears/MenuDock.git
cd MenuDock
make run
```

| Command | What it does |
|---|---|
| `make run` | Build (Debug) and launch from `.build` |
| `make install` | Build and install into `/Applications` |
| `make dmg` | Build a universal Release `.dmg` into `dist/` |
| `make project` | Regenerate `MenuDock.xcodeproj` after adding or removing files |
| `make icon` | Redraw `Resources/AppIcon.icns` |
| `make showcase` | Redraw the icon sheets and GIF in `docs/images/` |
| `make logs` | Tail the app's `os_log` output |
| `make stop` | Quit MenuDock |

`MenuDock.xcodeproj` and `Resources/AppIcon.icns` are both generated and git-ignored — run
`make project` after adding or removing source files.

---

## Contributing & internals

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

MenuDock is Swift 6, AppKit for the menu bar and SwiftUI for settings, with no third-party
dependencies. [**docs/ARCHITECTURE.md**](docs/ARCHITECTURE.md) is a long-form write-up of the
design decisions behind it — why the menu bar is AppKit rather than `MenuBarExtra`, how the
status-item ordering constraint works, why icons are drawn in code rather than shipped as assets,
and the profiling that took animated icons from 7.5% CPU to 0.6%. Worth reading before a
non-trivial PR.

## License

MIT — see [LICENSE](LICENSE).
