#!/usr/bin/env bash
# Wraps axprobe in a minimal, fully ad-hoc-signed app bundle (bundle/AXProbe.app) so the
# Accessibility grant belongs to a bundle ID rather than a bare binary. LSUIElement keeps it
# out of the Dock; launch with `open -g` so it never takes focus from the app under test.
# Re-grant Accessibility after every run of this script (the grant is tied to the cdhash).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=bundle/AXProbe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/axprobe "$APP/Contents/MacOS/axprobe"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.phase0.AXProbe</string>
  <key>CFBundleName</key><string>AXProbe</string>
  <key>CFBundleExecutable</key><string>axprobe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAccessibilityUsageDescription</key><string>AXProbe reads the focused text field's geometry and timing for the Phase 0 spike.</string>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier dev.phase0.AXProbe "$APP"
codesign --verify --strict "$APP" && echo "signature ok"
codesign -dvvv "$APP" 2>&1 | grep -E "Identifier=|flags=|CDHash=|Info.plist"
