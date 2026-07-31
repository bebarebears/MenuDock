# Changelog

All notable changes to MenuDock are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Universal (Apple Silicon + Intel) Release builds, packaged as a `.dmg`.
- GitHub Actions workflows for CI and tag-driven releases.
- Homebrew cask, installable from `bebarebears/tap`.

### Changed
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
