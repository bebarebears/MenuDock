#!/usr/bin/env bash
#
# Package a built MenuDock.app as a distributable .dmg.
#
#   Scripts/make-dmg.sh <path/to/MenuDock.app> [output-dir]
#
# The disk image contains the app beside a symlink to /Applications, which is the
# drag-to-install layout users expect. Prints the SHA-256 at the end — that is the
# checksum the Homebrew cask needs.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <path/to/MenuDock.app> [output-dir]}"
OUTDIR="${2:-dist}"

[ -d "$APP" ] || { echo "error: no app bundle at $APP" >&2; exit 1; }

NAME="$(basename "$APP" .app)"
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"

# Ad-hoc sign explicitly rather than trusting whatever the build left behind. An arm64
# binary with no signature at all will not launch on Apple Silicon, so this is the step
# that decides whether the download works.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/$NAME")"
echo "==> $NAME $VERSION  [$ARCHS]"

# A single-slice build is a green build that silently excludes half the users, so refuse
# to package one. The usual cause is a missing -destination 'generic/platform=macOS'.
for want in arm64 x86_64; do
	case "$ARCHS" in
		*"$want"*) ;;
		*) echo "error: $NAME is missing the $want slice (got: $ARCHS)" >&2; exit 1 ;;
	esac
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$OUTDIR"
DMG="$OUTDIR/$NAME-$VERSION.dmg"
rm -f "$DMG"

hdiutil create \
	-volname "$NAME" \
	-srcfolder "$STAGE" \
	-fs HFS+ \
	-format UDZO \
	-ov \
	"$DMG" >/dev/null

echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
echo "==> sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
