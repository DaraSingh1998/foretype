#!/usr/bin/env bash
# Pixel caret accuracy in a real app: opens a copy of a fixture in APP, moves the caret with
# Accessibility (AXSelectedTextRange; no keystrokes, no AppleScript) and compares the pixel
# caret with the Accessibility caret (`Foretype --caret-measure`).
#
# Safety: waits until the user has been idle for $IDLE s (default 20) before opening the
# window. The measurement touches only the test document's window, with FORETYPE_ONLY_APPS
# set to APP, and aborts as soon as APP stops being frontmost or another of its windows
# comes to the front. The document is closed unmodified (and APP quit if this script
# started it); the copy is deleted.
#
# usage: scripts/caret-measure.sh [APP] [BUNDLE_ID] [FIXTURE] [POSITIONS]
#        scripts/caret-measure.sh TextEdit com.apple.TextEdit
#        scripts/caret-measure.sh LibreOffice org.libreoffice.script
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
APP="${1:-TextEdit}"
BUNDLE="${2:-com.apple.TextEdit}"
FIXTURE="${3:-$ROOT/scripts/fixtures/caret-lines.txt}"
N="${4:-12}"
IDLE="${IDLE:-20}"
[ -x "$DRIVE" ] || swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE" || exit 1
[ -x "$BIN" ] || { echo "build first: scripts/build-mac.sh"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/foretype-caret.XXXXXX")"
STEM="foretype-caret-$(date +%s)"
DOC="$TMP/$STEM.${FIXTURE##*.}"
cp "$FIXTURE" "$DOC"
PID=""
WAS_RUNNING=0
app_pid() { pgrep -f "/$APP.app/Contents/MacOS/" | head -1; }
cleanup() {
  # Close the test window even if it never came to the front (keep the file until then).
  local p="${PID:-$(app_pid)}"
  if [ -n "$p" ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do "$DRIVE" close "$p" "$STEM" >/dev/null 2>&1 && break; sleep 1; done
    sleep 1
    [ "$WAS_RUNNING" = 0 ] && "$DRIVE" quit "$p" >/dev/null 2>&1
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
# A locked screen has no key window (no caret) and Accessibility returns empty windows.
locked() { ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q true; }
echo "waiting for an unlocked screen and ${IDLE}s of user inactivity..."
until ! locked && [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done
[ -n "$(app_pid)" ] && WAS_RUNNING=1
echo "user idle; opening $STEM in $APP at $(date +%T)"

open -a "$APP" "$DOC"
for _ in $(seq 120); do
  P="$("$DRIVE" front-pid)"
  case "$("$DRIVE" title "$P" 2>/dev/null)" in *"$STEM"*) PID="$P"; break ;; esac
  sleep 0.25
done
[ -n "$PID" ] || { echo "the test document did not come to the front"; exit 1; }
sleep 1.5
FORETYPE_ONLY_APPS="$BUNDLE" "$BIN" --caret-measure "$PID" "$STEM" "$N"
