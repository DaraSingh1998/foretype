#!/usr/bin/env bash
# Builds the Rust core and the Swift shell, then assembles build/Foretype.app.
#
# Environment:
#   FORETYPE_SIGN_IDENTITY       Code-signing identity: "Foretype" (self-signed, no hardened runtime),
#                                a "Developer ID Application: Name (TEAMID)" (hardened runtime and
#                                secure timestamp), or "-" to force ad hoc. Unset = "Foretype" if
#                                scripts/make-signing-cert.sh has installed it, else ad hoc. Ad-hoc
#                                grants (Accessibility, Screen Recording) are tied to one exact
#                                build; a certificate keeps them across rebuilds and updates.
#   FORETYPE_SIGN_KEYCHAIN       Keychain file to find the identity in, instead of the search list.
#   FORETYPE_SPARKLE=1           Link and embed the Sparkle 2 updater.
#   FORETYPE_FEED_URL            Appcast URL (Info.plist SUFeedURL; default: the latest GitHub
#                                release's appcast.xml).
#   FORETYPE_SPARKLE_PUBLIC_KEY  EdDSA public key (SUPublicEDKey; default:
#                                packaging/sparkle-public-key.txt).
#   FORETYPE_VERSION             Marketing version (default: core/Cargo.toml version).
#   FORETYPE_BUILD               Build number, CFBundleVersion (default: commit count).
#   FORETYPE_OUT                 Output folder for Foretype.app (default: build/).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET=14.0
LOCAL_IDENTITY="Foretype"
# SHA-1 of the self-signed identity, if present. Not `find-identity -v`: the certificate is
# self-signed and untrusted, which codesign and TCC don't mind but -v filters out.
local_identity() {
  security find-identity -p codesigning ${FORETYPE_SIGN_KEYCHAIN:+"$FORETYPE_SIGN_KEYCHAIN"} 2>/dev/null \
    | awk -v n="\"$LOCAL_IDENTITY\"" 'index($0, n) { print $2; exit }'
}
LOCAL_HASH="$(local_identity)"
IDENTITY="${FORETYPE_SIGN_IDENTITY:-${LOCAL_HASH:--}}"
case "$IDENTITY" in
  -) KIND=adhoc ;;
  "Developer ID Application:"*) KIND=developer-id ;;
  *) KIND=certificate ;;
esac
# Sign a self-signed identity by its SHA-1: codesign looks names up among trusted identities
# only on some versions ("no identity found" on the macos-26 runner), and this certificate is
# deliberately untrusted.
if [ "$KIND" = certificate ] && ! [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  NAMED="$IDENTITY"
  IDENTITY="$(security find-identity -p codesigning ${FORETYPE_SIGN_KEYCHAIN:+"$FORETYPE_SIGN_KEYCHAIN"} 2>/dev/null \
    | awk -v n="\"$NAMED\"" 'index($0, n) { print $2; exit }' || true)"
  [ -n "$IDENTITY" ] || { echo "signing identity \"$NAMED\" not found${FORETYPE_SIGN_KEYCHAIN:+ in $FORETYPE_SIGN_KEYCHAIN}"; exit 1; }
fi
SPARKLE="${FORETYPE_SPARKLE:-0}"
SCRATCH="$ROOT/mac/.build"
[ "$SPARKLE" = 1 ] && SCRATCH="$ROOT/mac/.build-sparkle"

(cd "$ROOT/core" && cargo build --release --lib)
(cd "$ROOT/mac" && FORETYPE_SPARKLE="$SPARKLE" swift build -c release --scratch-path "$SCRATCH" 2>&1 \
  | grep -v "was built for newer 'macOS' version" || true)
[ -x "$SCRATCH/release/Foretype" ] || { echo "swift build failed"; exit 1; }

APP="${FORETYPE_OUT:-$ROOT/build}/Foretype.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$SCRATCH/release/Foretype" "$APP/Contents/MacOS/Foretype"
# UI translations (mac/Localization/<lang>.lproj), looked up through Bundle.main. Not a SwiftPM
# resource bundle: SwiftPM would put Foretype_Foretype.bundle at the app's top level, which
# code signing rejects.
for lproj in "$ROOT"/mac/Localization/*.lproj; do
  ditto "$lproj" "$APP/Contents/Resources/$(basename "$lproj")"
done
# The app icon (scripts/make-icon.swift draws it).
cp "$ROOT/mac/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Licences (THIRD_PARTY_NOTICES.md says what ships).
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/LICENSE-MIT" "$ROOT/LICENSE-APACHE" "$APP/Contents/Resources/"
cp "$ROOT/core/data/emoji-LICENSE.txt" "$APP/Contents/Resources/gemoji-LICENSE.txt"
LANGS=""
for lproj in "$ROOT"/mac/Localization/*.lproj; do
  LANGS="$LANGS<string>$(basename "$lproj" .lproj)</string>"
done
VERSION="${FORETYPE_VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/core/Cargo.toml" | head -1)}"
BUILD="${FORETYPE_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

SPARKLE_KEYS=""
if [ "$SPARKLE" = 1 ]; then
  FW_SRC="$(find "$SCRATCH/artifacts" -type d -path "*macos*" -name Sparkle.framework 2>/dev/null | head -1)"
  [ -n "$FW_SRC" ] || { echo "Sparkle.framework not found under $SCRATCH/artifacts"; exit 1; }
  ditto "$FW_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
  SPARKLE_LICENSE="$(find "$SCRATCH/artifacts" -maxdepth 3 -name LICENSE -path "*Sparkle*" 2>/dev/null | head -1)"
  [ -n "$SPARKLE_LICENSE" ] && cp "$SPARKLE_LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
  FEED_URL="${FORETYPE_FEED_URL:-https://github.com/DaraSingh1998/foretype/releases/latest/download/appcast.xml}"
  PUBLIC_KEY="${FORETYPE_SPARKLE_PUBLIC_KEY:-$(cat "$ROOT/packaging/sparkle-public-key.txt" 2>/dev/null || true)}"
  if [ -n "$PUBLIC_KEY" ]; then
    # Checked daily; found updates download and install without asking (UpdateController
    # installs them once the user is idle). Both can be turned off in Settings.
    SPARKLE_KEYS="  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>"
    # A feed on this Mac (scripts/sparkle-local-test.sh) is plain HTTP: let ATS allow it.
    case "$FEED_URL" in
      http://127.0.0.1*|http://localhost*)
        SPARKLE_KEYS="$SPARKLE_KEYS
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>" ;;
    esac
  else
    echo "note: Sparkle embedded but no EdDSA public key (packaging/sparkle-public-key.txt): updates stay off"
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LANGS}</array>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Foretype contributors. MIT or Apache-2.0.</string>
  <key>NSAccessibilityUsageDescription</key><string>Foretype reads the text field you are typing in to suggest the next words, and types the words you accept. Everything stays on this Mac.</string>
  <key>NSContactsUsageDescription</key><string>Foretype reads your own card (My Card) once, when you ask it to fill in Settings ▸ About You. Nothing leaves this Mac.</string>
${SPARKLE_KEYS}
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The hardened runtime enforces library validation, and neither ad-hoc nor self-signed
# signatures carry a Team ID, so such an app with Sparkle.framework embedded would fail to
# launch ("Library missing"). Notarization needs the runtime but also a Developer ID, so only
# a Developer ID gets it, and the secure timestamp with it.
OPTS=()
case "$KIND" in
  developer-id) OPTS=(--options runtime --timestamp) ;;
  certificate) OPTS=(--timestamp=none) ;;
esac
[ "$KIND" != adhoc ] && [ -n "${FORETYPE_SIGN_KEYCHAIN:-}" ] && OPTS+=(--keychain "$FORETYPE_SIGN_KEYCHAIN")
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
# The entitlement lets a hardened-runtime build read the user's own Contacts card (About You).
sign --identifier dev.foretype.Foretype --entitlements "$ROOT/mac/Foretype.entitlements" "$APP"
codesign --verify --strict --deep "$APP"
case "$KIND" in
  adhoc) SIGNED="ad hoc; re-add Accessibility and Screen Recording after each rebuild, or run scripts/make-signing-cert.sh once" ;;
  certificate) SIGNED="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1), no hardened runtime; grants carry over to the next build" ;;
  developer-id) SIGNED="$IDENTITY, hardened runtime" ;;
esac
echo "built $APP ($VERSION build $BUILD, signed: $SIGNED)"
