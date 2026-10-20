#!/usr/bin/env bash
# Builds the Rust core and the Swift shell, then assembles build/Foretype.app.
#
# Environment:
#   FORETYPE_SIGN_IDENTITY       Code-signing identity, e.g. "Developer ID Application: Name (TEAMID)".
#                                Unset = ad-hoc. A stable identity also keeps the Accessibility grant
#                                across rebuilds (ad-hoc grants are tied to one exact build).
#   FORETYPE_SPARKLE=1           Link and embed the Sparkle 2 updater.
#   FORETYPE_FEED_URL            Appcast URL (Info.plist SUFeedURL).
#   FORETYPE_SPARKLE_PUBLIC_KEY  EdDSA public key from Sparkle's generate_keys (SUPublicEDKey).
#   FORETYPE_VERSION             Marketing version (default: core/Cargo.toml version).
#   FORETYPE_BUILD               Build number, CFBundleVersion (default: commit count).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET=14.0
IDENTITY="${FORETYPE_SIGN_IDENTITY:--}"
SPARKLE="${FORETYPE_SPARKLE:-0}"
SCRATCH="$ROOT/mac/.build"
[ "$SPARKLE" = 1 ] && SCRATCH="$ROOT/mac/.build-sparkle"

(cd "$ROOT/core" && cargo build --release --lib)
(cd "$ROOT/mac" && FORETYPE_SPARKLE="$SPARKLE" swift build -c release --scratch-path "$SCRATCH" 2>&1 \
  | grep -v "was built for newer 'macOS' version" || true)
[ -x "$SCRATCH/release/Foretype" ] || { echo "swift build failed"; exit 1; }

APP="$ROOT/build/Foretype.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$SCRATCH/release/Foretype" "$APP/Contents/MacOS/Foretype"
VERSION="${FORETYPE_VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/core/Cargo.toml" | head -1)}"
BUILD="${FORETYPE_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

SPARKLE_KEYS=""
if [ "$SPARKLE" = 1 ]; then
  FW_SRC="$(find "$SCRATCH/artifacts" -type d -path "*macos*" -name Sparkle.framework 2>/dev/null | head -1)"
  [ -n "$FW_SRC" ] || { echo "Sparkle.framework not found under $SCRATCH/artifacts"; exit 1; }
  ditto "$FW_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
  if [ -n "${FORETYPE_FEED_URL:-}" ] && [ -n "${FORETYPE_SPARKLE_PUBLIC_KEY:-}" ]; then
    SPARKLE_KEYS="  <key>SUFeedURL</key><string>${FORETYPE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${FORETYPE_SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>"
    # A feed on this Mac (scripts/sparkle-local-test.sh) is plain HTTP: let ATS allow it.
    case "$FORETYPE_FEED_URL" in
      http://127.0.0.1*|http://localhost*)
        SPARKLE_KEYS="$SPARKLE_KEYS
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>" ;;
    esac
  else
    echo "note: Sparkle embedded but FORETYPE_FEED_URL / FORETYPE_SPARKLE_PUBLIC_KEY unset: updates stay off"
  fi
fi

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.foretype.Foretype</string>
  <key>CFBundleName</key><string>Foretype</string>
  <key>CFBundleDisplayName</key><string>Foretype</string>
  <key>CFBundleExecutable</key><string>Foretype</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Foretype contributors. MIT or Apache-2.0.</string>
  <key>NSAccessibilityUsageDescription</key><string>Foretype reads the text field you are typing in to suggest the next words, and types the words you accept. Everything stays on this Mac.</string>
${SPARKLE_KEYS}
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The hardened runtime enforces library validation, and ad-hoc signatures carry no Team ID,
# so an ad-hoc app with Sparkle.framework embedded would fail to launch ("Library missing").
# Notarization needs the runtime but also a Developer ID, so only real identities get it.
OPTS=()
[ "$IDENTITY" != "-" ] && OPTS=(--options runtime --timestamp)
sign() { codesign --force ${OPTS[@]+"${OPTS[@]}"} --sign "$IDENTITY" "$@"; }
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  # Inside-out, as Sparkle's documentation describes for apps signed outside Xcode.
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  for xpc in "$FW"/Versions/B/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    if [ "$(basename "$xpc")" = "Downloader.xpc" ]; then sign --preserve-metadata=entitlements "$xpc"; else sign "$xpc"; fi
  done
  [ -e "$FW/Versions/B/Autoupdate" ] && sign "$FW/Versions/B/Autoupdate"
  [ -e "$FW/Versions/B/Updater.app" ] && sign "$FW/Versions/B/Updater.app"
  sign "$FW"
fi
rmdir "$APP/Contents/Frameworks" 2>/dev/null || true
sign --identifier dev.foretype.Foretype "$APP"
codesign --verify --strict --deep "$APP"
echo "built $APP ($VERSION build $BUILD, signed: $IDENTITY)"
