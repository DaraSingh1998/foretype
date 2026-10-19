#!/usr/bin/env bash
# Builds the Rust core and the Swift shell, then assembles build/Foretype.app.
#
# Signing: set FORETYPE_SIGN_IDENTITY to a Developer ID (or any stable code-signing
# identity) so the Accessibility grant survives rebuilds. Without it the app is ad-hoc
# signed, and macOS ties the grant to this exact build: remove and re-add Foretype under
# Privacy & Security > Accessibility after every rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET=14.0

(cd "$ROOT/core" && cargo build --release --lib)
(cd "$ROOT/mac" && swift build -c release 2>&1 | grep -v "was built for newer 'macOS' version" || true)

APP="$ROOT/build/Foretype.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/mac/.build/release/Foretype" "$APP/Contents/MacOS/Foretype"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/core/Cargo.toml" | head -1)"
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
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAccessibilityUsageDescription</key><string>Foretype reads the text field you are typing in to suggest the next words, and types the words you accept. Everything stays on this Mac.</string>
</dict>
</plist>
PLIST
codesign --force --options runtime --sign "${FORETYPE_SIGN_IDENTITY:--}" --identifier dev.foretype.Foretype "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
