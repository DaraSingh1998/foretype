#!/usr/bin/env bash
# End-to-end test of a silent Sparkle update on this Mac, signed the way releases are: no
# Developer ID, a self-signed "Foretype" identity (here a throwaway one in a temporary
# keychain) and an EdDSA key (a throwaway one).
#
# Builds an old version (0.0.1, build 1) and packages a new one (0.0.2, build 2), both pointing
# at a feed on 127.0.0.1, serves the feed and the DMG, and starts the old app with
# FORETYPE_UPDATE_CHECK_NOW=1 (a background check at launch, as the daily one) and
# FORETYPE_UPDATE_IDLE=0 (install without waiting for the user to be idle). Sparkle should
# download the DMG, accept both its EdDSA signature and its code signature (same certificate
# as the old app), replace the app without showing anything and relaunch it. Prints PASS/FAIL.
#
# Safety: the old app runs with FORETYPE_ONLY_APPS=none.invalid, so it reads and intercepts
# nothing. The relaunched copy carries no Accessibility grant (a new certificate), so it can't
# either; at most its setup window appears until the test quits it. The Sparkle keys the test
# adds to the app's defaults (dev.foretype.Foretype) are removed afterwards.
#
#   scripts/sparkle-local-test.sh [WORK_DIR]     (default: a new temporary directory)
#   FORETYPE_TEST_PORT                           (default 8977)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$(mktemp -d -t foretype-sparkle)}"
PORT="${FORETYPE_TEST_PORT:-8977}"
FEED="http://127.0.0.1:$PORT/appcast.xml"
DOMAIN=dev.foretype.Foretype
mkdir -p "$WORK/serve"
KC="$WORK/signing.keychain-db"
SERVER=""
APP="$WORK/Foretype.app"
BIN="$APP/Contents/MacOS/Foretype"
SU_BEFORE="$(defaults read "$DOMAIN" 2>/dev/null | grep -o '^ *SU[A-Za-z]*' | tr -d ' ' || true)"

cleanup() {
  pkill -f "$BIN" 2>/dev/null || true
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null
  security delete-keychain "$KC" 2>/dev/null || true
  for k in $(defaults read "$DOMAIN" 2>/dev/null | grep -o '^ *SU[A-Za-z]*' | tr -d ' '); do
    echo "$SU_BEFORE" | grep -qx "$k" || defaults delete "$DOMAIN" "$k" 2>/dev/null || true
  done
  git -C "$ROOT" checkout -q mac/Package.resolved 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use (another test server?): stop it or set FORETYPE_TEST_PORT"
  exit 1
fi

echo "== signing identity and update key (throwaway)"
security create-keychain -p test "$KC"
security unlock-keychain -p test "$KC"
FORETYPE_SIGN_KEYCHAIN="$KC" FORETYPE_YES=1 "$ROOT/scripts/make-signing-cert.sh" "$WORK/signing.p12" >"$WORK/cert.log" 2>&1
security set-key-partition-list -S apple-tool:,apple: -s -k test "$KC" >/dev/null
PUB="$(swift "$ROOT/tools/sparkle/edkey.swift" generate "$WORK/ed25519.key")"
common=(FORETYPE_SPARKLE=1 "FORETYPE_FEED_URL=$FEED" "FORETYPE_SPARKLE_PUBLIC_KEY=$PUB"
        "FORETYPE_SIGN_KEYCHAIN=$KC" FORETYPE_SIGN_IDENTITY=Foretype)

echo "== old app 0.0.1"
env "${common[@]}" FORETYPE_VERSION=0.0.1 FORETYPE_BUILD=1 FORETYPE_OUT="$WORK/old" \
  "$ROOT/scripts/build-mac.sh" 2>&1 | tail -1
rm -rf "$APP"
ditto "$WORK/old/Foretype.app" "$APP"

echo "== new release 0.0.2"
env "${common[@]}" FORETYPE_VERSION=0.0.2 FORETYPE_BUILD=2 FORETYPE_OUT="$WORK/new" \
  FORETYPE_SPARKLE_KEY_FILE="$WORK/ed25519.key" FORETYPE_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
  "$ROOT/scripts/package-mac.sh" 2>&1 | grep -E "^(appcast|dmg):"
cp "$WORK/new/Foretype-0.0.2.dmg" "$WORK/new/appcast.xml" "$WORK/serve/"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/serve" >"$WORK/server.log" 2>&1 &
SERVER=$!
sleep 1

echo "== starting 0.0.1 (update check at launch, install at once)"
START="$(date '+%Y-%m-%d %H:%M:%S')"
FORETYPE_UPDATE_CHECK_NOW=1 FORETYPE_UPDATE_IDLE=0 FORETYPE_ONLY_APPS=none.invalid \
  "$BIN" >"$WORK/old-app.log" 2>&1 &
OLD_PID=$!
VERSION=""
for _ in $(seq 90); do
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [ "$VERSION" = 0.0.2 ] && break
  sleep 2
done
sleep 5
NEW_PID="$(pgrep -f "$BIN" | grep -vx "$OLD_PID" | head -1 || true)"
log show --start "$START" --style compact --predicate 'subsystem BEGINSWITH "org.sparkle-project"' >"$WORK/sparkle.log" 2>/dev/null || true

FAILED=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi; }
check "feed and DMG downloaded" 'grep -q "Foretype-0.0.2.dmg" "$WORK/server.log"'
check "app replaced with 0.0.2" '[ "$VERSION" = 0.0.2 ]'
check "old app quit" '! kill -0 "$OLD_PID" 2>/dev/null'
check "relaunched" '[ -n "$NEW_PID" ]'
check "same designated requirement" '[ "$(codesign -dr - "$WORK/old/Foretype.app" 2>&1 | grep designated)" = "$(codesign -dr - "$APP" 2>&1 | grep designated)" ]'
check "no code-signature mismatch logged" '! grep -qi "doesn.t match\|does not match" "$WORK/sparkle.log"'
echo "--- sparkle log (last lines):"
grep -v "^Timestamp" "$WORK/sparkle.log" | tail -8 || true
echo "work dir: $WORK"
exit "$FAILED"
