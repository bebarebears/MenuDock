# Contributing to MenuDock

Thanks for taking a look. Bug reports, icon suggestions and pull requests are all welcome.

## Getting set up

```bash
brew install xcodegen
git clone https://github.com/bebarebears/MenuDock.git
cd MenuDock
make run
```

`MenuDock.xcodeproj` is **generated from `project.yml`** and git-ignored, so it never shows up
in a diff. Run `make project` after adding or removing a source file, or Xcode will not see it.
`Resources/AppIcon.icns` is generated too, by `make icon`.

Useful while developing:

| Command | What it does |
|---|---|
| `make run` | Build and relaunch |
| `make logs` | Tail `os_log` output |
| `make config` | Print the current on-disk configuration |
| `make reset` | **Deletes your settings and custom icons.** Handy for testing first-run, destructive otherwise |

## Before opening a pull request

**Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).** It is long, but it documents the
constraints that are not visible from the code — why the menu bar is AppKit rather than
`MenuBarExtra`, why the status item deliberately has no `menu`, why there is no `autosaveName`,
and three optimisations that were tried and did not work. Most surprising-looking code in this
project is surprising for a reason that is written down there.

A few things that will come up in review:

- **CI builds Release, which is universal (arm64 + x86_64).** Code that only compiles for one
  slice fails the build.
- **Everything is `@MainActor` by default** (`SWIFT_DEFAULT_ACTOR_ISOLATION`). Mark genuinely
  background code `nonisolated` rather than reaching for `@unchecked Sendable`.
- **New configuration fields must decode with `decodeIfPresent` and a default.** Swift's
  synthesized `Decodable` throws on an absent key, so a plain new property invalidates every
  config file already on users' disks.
- **Never delete user artwork.** `IconLibrary` moves unreferenced icons to `Icons/Unused/`.
  There is a data-loss incident behind that rule, described in the architecture doc.
- **No third-party dependencies**, and please keep it that way.

## Adding a built-in icon

Built-in glyphs are drawn in code on a 24 × 24 y-down grid — see `Sources/MenuDock/Icons/Builtin/`.
Add static glyphs to `StaticIcons.swift`, animated ones to `AnimatedIcons.swift`.

Two rules learned the hard way:

- **Look at it before you ship it.** Render at both 46pt and 18pt. The first attempt at a flame
  read as a water droplet, and a USB stick turned out to be the battery silhouette reversed.
- **Category glyphs, not brand logos.** One "Browser" icon serves Safari, Chrome, Arc and
  Firefox. Redrawing third-party marks is a trademark problem, and mismatched logos read badly
  in a menu bar. Users who want a specific mark can drop in their own SVG.

Animation should be restrained: 2.2–4.5s periods, eased rather than linear, small amplitude or
pure opacity. A menu bar sits in peripheral vision all day, and anything sharp there reads as
an alert.

## Reporting a bug

`make logs` output is the single most useful thing you can attach, along with your macOS
version and whether you installed via Homebrew or the DMG.

## Releases

Maintainers only:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

That builds a universal `.dmg`, publishes a GitHub Release, and bumps the Homebrew cask.
See [homebrew/README.md](homebrew/README.md) for the tap.
