#!/usr/bin/env bash
# End-to-end Sparkle update test on this Mac, without a Developer ID or real release keys.
#
# Builds an old version (0.0.1, build 1) and a new one (0.0.2, build 2) of the Sparkle
# build, both ad-hoc signed and pointing at a feed on 127.0.0.1, signs the new DMG with a
# throwaway EdDSA key, writes the appcast and serves it. Then:
#
#   open "$WORK/Foretype.app"   → menu-bar icon → Check for Updates… → Install Update
#
# Sparkle downloads the DMG, checks the EdDSA signature, replaces the app in place and
# relaunches it; `defaults read "$WORK/Foretype.app/Contents/Info" CFBundleShortVersionString`
# then prints 0.0.2. The old app has no Accessibility grant (new ad-hoc identity), so it
# never reads other apps' text while you test.
#
#   scripts/sparkle-local-test.sh [WORK_DIR]     (default: a new temporary directory)
#   FORETYPE_TEST_PORT                           (default 8977)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$(mktemp -d -t foretype-sparkle)}"
PORT="${FORETYPE_TEST_PORT:-8977}"
FEED="http://127.0.0.1:$PORT/appcast.xml"
mkdir -p "$WORK"

PUB="$(swift "$ROOT/tools/sparkle/edkey.swift" generate "$WORK/ed25519.key")"
common=(FORETYPE_SPARKLE=1 "FORETYPE_FEED_URL=$FEED" "FORETYPE_SPARKLE_PUBLIC_KEY=$PUB")

env "${common[@]}" FORETYPE_VERSION=0.0.1 FORETYPE_BUILD=1 "$ROOT/scripts/build-mac.sh" >/dev/null
rm -rf "$WORK/Foretype.app"
ditto "$ROOT/build/Foretype.app" "$WORK/Foretype.app"

env "${common[@]}" FORETYPE_VERSION=0.0.2 FORETYPE_BUILD=2 "$ROOT/scripts/package-mac.sh" >/dev/null
cp "$ROOT/build/Foretype-0.0.2.dmg" "$WORK/"
SIG="$(swift "$ROOT/tools/sparkle/edkey.swift" sign "$WORK/ed25519.key" "$WORK/Foretype-0.0.2.dmg")"

cat >"$WORK/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
  <title>Foretype (local test)</title>
  <item>
    <title>Foretype 0.0.2</title>
    <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
    <sparkle:version>2</sparkle:version>
    <sparkle:shortVersionString>0.0.2</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure url="http://127.0.0.1:$PORT/Foretype-0.0.2.dmg" $SIG type="application/octet-stream"/>
  </item>
</channel>
</rss>
XML

echo "old app:  $WORK/Foretype.app (0.0.1)"
echo "feed:     $FEED"
echo "serving $WORK on 127.0.0.1:$PORT (Ctrl-C to stop)"
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK"
