#!/usr/bin/env bash
# End-to-end test of Sparkle updates on this Mac, signed the way releases are: no Developer
# ID, a self-signed "Foretype" identity (here a throwaway one in a temporary keychain) and an
# EdDSA key (a throwaway one).
#
# Builds an old version (0.0.1, build 1) and packages a new one (0.0.2, build 2), both pointing
# at a feed on 127.0.0.1, serves the feed and the DMG, and starts the old app twice with
# FORETYPE_UPDATE_CHECK_NOW=1 (a background check at launch, as the daily one):
#
# 1. Automatic install off (-SUAutomaticallyUpdate NO, in the argument domain only). The check
#    should mark the menu-bar icon instead of opening Sparkle's window (gentle reminder), and
#    the menu and Settings ▸ General should offer 0.0.2. The app reports what they show
#    (FORETYPE_UPDATE_REPORT, and a picture of the General pane next to the report); SIGUSR1
#    then chooses the menu's update line, which should open Sparkle's window for 0.0.2.
#    Started again without a check, the app should still offer 0.0.2; 0.0.2 itself should
#    offer nothing and clear the stored offer.
# 2. Automatic install on, FORETYPE_UPDATE_IDLE=0 (install without waiting for the user to be
#    idle). Sparkle should download the DMG, accept both its EdDSA signature and its code
#    signature (same certificate as the old app), replace the app without showing anything and
#    relaunch it. Prints PASS/FAIL.
#
# Safety: the old app runs with FORETYPE_ONLY_APPS=none.invalid, so it reads and intercepts
# nothing. The relaunched copy carries no Accessibility grant (a new certificate), so it can't
# either. Their setup window, and in step 1 Sparkle's window, appear until the test quits
# them. The copies the test starts don't touch the Keychain (a throwaway certificate would get
# an access prompt): FORETYPE_ABOUT_YOU={} and -personalize NO (argument domain, nothing
# written). Sparkle relaunches 0.0.2 without them, so where About You details or writing
# history are saved, step 2 can still show a Keychain prompt for "Foretype": click Deny (the
# test quits the app). FORETYPE_TEST_WAITING_ONLY=1 skips step 2. The Sparkle keys and the waiting update the test adds to the app's defaults
# (dev.foretype.Foretype) are put back afterwards.
#
#   scripts/sparkle-local-test.sh [WORK_DIR]     (default: a new temporary directory)
#   FORETYPE_TEST_PORT                           (default 8977)
#   FORETYPE_TEST_WAITING_ONLY=1                 step 1 only: no install, no relaunch, no Keychain prompt
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
# The waiting update UpdateController keeps (the installed app's, if it has one).
WAITING_VERSION_BEFORE="$(defaults read "$DOMAIN" updateAvailableVersion 2>/dev/null || echo "<none>")"
WAITING_BUILD_BEFORE="$(defaults read "$DOMAIN" updateAvailableBuild 2>/dev/null || echo "<none>")"

cleanup() {
  pkill -f "$BIN" 2>/dev/null || true
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null
  security delete-keychain "$KC" 2>/dev/null || true
  for k in $(defaults read "$DOMAIN" 2>/dev/null | grep -o '^ *SU[A-Za-z]*' | tr -d ' '); do
    echo "$SU_BEFORE" | grep -qx "$k" || defaults delete "$DOMAIN" "$k" 2>/dev/null || true
  done
  for kv in "updateAvailableVersion=$WAITING_VERSION_BEFORE" "updateAvailableBuild=$WAITING_BUILD_BEFORE"; do
    if [ "${kv#*=}" = "<none>" ]; then defaults delete "$DOMAIN" "${kv%%=*}" 2>/dev/null || true
    else defaults write "$DOMAIN" "${kv%%=*}" -string "${kv#*=}"; fi
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

FAILED=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi; }
# Waits up to $2 seconds for the report to contain $1.
wait_report() {
  for _ in $(seq "$2"); do grep -qF -- "$1" "$REPORT" 2>/dev/null && return 0; sleep 1; done
  return 1
}

echo "== 1. starting 0.0.1 with automatic install off (update check at launch)"
REPORT="$WORK/report.txt"
rm -f "$REPORT"
FORETYPE_UPDATE_CHECK_NOW=1 FORETYPE_ONLY_APPS=none.invalid FORETYPE_UPDATE_REPORT="$REPORT" \
  FORETYPE_ABOUT_YOU='{}' "$BIN" -SUAutomaticallyUpdate NO -personalize NO >"$WORK/waiting-app.log" 2>&1 &
WAIT_PID=$!
wait_report "Update Available: 0.0.2" 60 || true
sleep 2
cp "$REPORT" "$WORK/report-found.txt" 2>/dev/null || touch "$WORK/report-found.txt"
cp "$REPORT.png" "$WORK/settings-general.png" 2>/dev/null || true
F="$WORK/report-found.txt"
check "menu offers 0.0.2" 'grep -qx "menu: Update Available: 0.0.2 — Install…" "$F"'
check "menu-bar icon marked" 'grep -q "^icon: .*update available" "$F"'
check "Settings offers 0.0.2" 'grep -q "^settings: 0.0.1 (build 1) | Version 0.0.2 is available \[Install…\]" "$F"'
check "no Sparkle window yet (gentle reminder)" '! grep -q "SUUpdateAlert" "$F"'
check "not installed" '[ "$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")" = 0.0.1 ]'
kill -USR1 "$WAIT_PID" 2>/dev/null || true
wait_report "SUUpdateAlert" 15 || true
cp "$REPORT" "$WORK/report-chosen.txt" 2>/dev/null || touch "$WORK/report-chosen.txt"
check "menu line opens Sparkle's window" 'grep -q "^window: .*(SUUpdateAlert)" "$WORK/report-chosen.txt"'
kill "$WAIT_PID" 2>/dev/null || true
for _ in $(seq 20); do kill -0 "$WAIT_PID" 2>/dev/null || break; sleep 0.5; done
rm -f "$REPORT"
FORETYPE_ONLY_APPS=none.invalid FORETYPE_UPDATE_REPORT="$REPORT" FORETYPE_ABOUT_YOU='{}' \
  "$BIN" -SUAutomaticallyUpdate NO -personalize NO >"$WORK/relaunch-app.log" 2>&1 &
WAIT_PID=$!
wait_report "settings:" 20 || true
check "still offered after a relaunch" 'grep -qx "menu: Update Available: 0.0.2 — Install…" "$REPORT"'
kill "$WAIT_PID" 2>/dev/null || true
for _ in $(seq 20); do kill -0 "$WAIT_PID" 2>/dev/null || break; sleep 0.5; done
# 0.0.2 itself, started as Sparkle's relaunch would (which can't be given FORETYPE_ABOUT_YOU,
# so it may wait on a Keychain prompt in step 2): nothing to offer, the stored offer cleared.
rm -f "$REPORT"
FORETYPE_ONLY_APPS=none.invalid FORETYPE_UPDATE_REPORT="$REPORT" FORETYPE_ABOUT_YOU='{}' \
  "$WORK/new/Foretype.app/Contents/MacOS/Foretype" -SUAutomaticallyUpdate NO -personalize NO >"$WORK/new-app.log" 2>&1 &
WAIT_PID=$!
wait_report "settings:" 20 || true
check "0.0.2 offers nothing" 'grep -q "^settings: 0.0.2 (build 2)$" "$REPORT" && ! grep -q "Update Available" "$REPORT"'
check "offer cleared once installed" '! defaults read "$DOMAIN" updateAvailableBuild >/dev/null 2>&1'
kill "$WAIT_PID" 2>/dev/null || true
for _ in $(seq 20); do kill -0 "$WAIT_PID" 2>/dev/null || break; sleep 0.5; done

if [ "${FORETYPE_TEST_WAITING_ONLY:-0}" = 1 ]; then
  echo "work dir: $WORK (report-found.txt, report-chosen.txt, settings-general.png)"
  exit "$FAILED"
fi

echo "== 2. starting 0.0.1 with automatic install on (update check at launch, install at once)"
START="$(date '+%Y-%m-%d %H:%M:%S')"
FORETYPE_UPDATE_CHECK_NOW=1 FORETYPE_UPDATE_IDLE=0 FORETYPE_ONLY_APPS=none.invalid FORETYPE_ABOUT_YOU='{}' \
  "$BIN" -SUAutomaticallyUpdate YES -personalize NO >"$WORK/old-app.log" 2>&1 &
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

check "feed and DMG downloaded" 'grep -q "Foretype-0.0.2.dmg" "$WORK/server.log"'
check "app replaced with 0.0.2" '[ "$VERSION" = 0.0.2 ]'
check "old app quit" '! kill -0 "$OLD_PID" 2>/dev/null'
check "relaunched" '[ -n "$NEW_PID" ]'
check "same designated requirement" '[ "$(codesign -dr - "$WORK/old/Foretype.app" 2>&1 | grep designated)" = "$(codesign -dr - "$APP" 2>&1 | grep designated)" ]'
check "no code-signature mismatch logged" '! grep -qi "doesn.t match\|does not match" "$WORK/sparkle.log"'
echo "--- sparkle log (last lines):"
grep -v "^Timestamp" "$WORK/sparkle.log" | tail -8 || true
echo "work dir: $WORK (step 1: report-found.txt, report-chosen.txt, settings-general.png)"
exit "$FAILED"
