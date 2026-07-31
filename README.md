<div align="center">

<img src="docs/images/icon.png" width="128" alt="MenuDock icon">

# MenuDock

**Your Dock, in the menu bar.**

Pin any app or folder to the macOS menu bar. Click to launch, activate or open —
exactly like a Dock tile, without the Dock.

[![Download](https://img.shields.io/github/v/release/bebarebears/MenuDock?label=download&style=for-the-badge)](https://github.com/bebarebears/MenuDock/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?style=for-the-badge&logo=apple)](https://github.com/bebarebears/MenuDock/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)](LICENSE)

</div>

<!--
  SCREENSHOTS — the one thing still missing. Drop 2–3 PNGs into docs/images/ and
  paste the markdown below back in here. Suggested shots:
    menu-bar.png  — a close crop of your menu bar showing 5–6 MenuDock icons
    settings.png  — the Settings window with an item selected
    gallery.png   — the built-in icon gallery
  Then use:  ![MenuDock in the menu bar](docs/images/menu-bar.png)
-->

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

**Any icon, any size.** Choose the app's own icon, one of **106 built-in glyphs** (78 static, 28
gently animated), an SF Symbol, or drop in your own PNG or SVG. Every item can override the global
icon size, so Finder can sit a little larger than the rest.

**Group things.** Put several apps behind one icon and they become a dropdown menu.

**One click to launch.** Click launches if the app is closed, brings it forward if it is open, and
restores a window if it is running with none — the same behaviour as a real Dock tile. A dot marks
what is running. Right-click for hide, quit and new-window.

**Reorder by dragging** the list in Settings; the menu bar follows.

**It stays out of the way.** Animation is suppressed under Reduce Motion, pauses when your screen
sleeps or locks, and halves its frame rate in Low Power Mode. Steady-state CPU use is under 1%.

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
