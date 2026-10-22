#!/usr/bin/env bash
# Installs (or updates) Foretype from its latest GitHub release:
#
#   curl -fsSL https://github.com/DaraSingh1998/foretype/releases/latest/download/install.sh | bash
#
# Downloads the DMG with curl, checks its SHA-256 against the one published with it, copies
# Foretype.app to /Applications (~/Applications if /Applications isn't writable) and opens it.
# Foretype is signed with its own certificate, not an Apple Developer ID: a DMG downloaded in
# a browser has to be allowed once in System Settings ▸ Privacy & Security ("Open Anyway"),
# while a file downloaded with curl isn't marked as downloaded, so this script needs no such
# step. After that, the app updates itself.
#
# Testing: FORETYPE_RELEASE_BASE (another release folder URL), FORETYPE_INSTALL_DIR (instead of
# /Applications), FORETYPE_NO_OPEN=1 (don't start the app).
set -euo pipefail
REPO="DaraSingh1998/foretype"
BASE="${FORETYPE_RELEASE_BASE:-https://github.com/$REPO/releases/latest/download}"
die() { echo "Foretype install: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Foretype runs on macOS only."
[ "$(uname -m)" = arm64 ] || die "Foretype needs a Mac with Apple silicon (M1 or later)."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || die "Foretype needs macOS 14 Sonoma or later (this Mac has $(sw_vers -productVersion))."

TMP="$(mktemp -d -t foretype-install)"
MNT="$TMP/mnt"
cleanup() {
  [ -d "$MNT" ] && hdiutil detach "$MNT" -quiet 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

APPCAST="$(curl -fsSL "$BASE/appcast.xml")" || die "couldn't reach $BASE/appcast.xml"
URL="$(printf '%s' "$APPCAST" | sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' | head -1)"
VERSION="$(printf '%s' "$APPCAST" | sed -n 's/.*<sparkle:shortVersionString>\(.*\)<\/sparkle:shortVersionString>.*/\1/p' | head -1)"
[ -n "$URL" ] && [ -n "$VERSION" ] || die "the release feed has no download"

echo "Downloading Foretype $VERSION..."
curl -fL --progress-bar -o "$TMP/Foretype.dmg" "$URL" || die "download failed: $URL"
EXPECTED="$(curl -fsSL "$URL.sha256" | cut -d' ' -f1)" || die "couldn't get $URL.sha256"
ACTUAL="$(shasum -a 256 "$TMP/Foretype.dmg" | cut -d' ' -f1)"
[ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch (expected $EXPECTED, got $ACTUAL)"

mkdir -p "$MNT"
hdiutil attach "$TMP/Foretype.dmg" -nobrowse -readonly -mountpoint "$MNT" -quiet || die "couldn't open the DMG"
[ -d "$MNT/Foretype.app" ] || die "the DMG has no Foretype.app"

DEST="${FORETYPE_INSTALL_DIR:-/Applications}"
[ -n "${FORETYPE_INSTALL_DIR:-}" ] || [ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
RUNNING="$DEST/Foretype.app/Contents/MacOS/Foretype"
if pgrep -f "$RUNNING" >/dev/null; then
  echo "Quitting the running Foretype..."
  pkill -TERM -f "$RUNNING" || true
  for _ in $(seq 20); do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.5; done
fi
rm -rf "$DEST/Foretype.app"
ditto "$MNT/Foretype.app" "$DEST/Foretype.app"
xattr -dr com.apple.quarantine "$DEST/Foretype.app" 2>/dev/null || true
[ "${FORETYPE_NO_OPEN:-0}" = 1 ] || open "$DEST/Foretype.app"

cat <<DONE

Foretype $VERSION is installed in $DEST and starting.
Its setup window asks for Accessibility (needed to read and type in text fields), offers
Screen Recording (optional) and downloads a language model (about 1 GB, once). After that
it lives in the menu bar and updates itself.
DONE
