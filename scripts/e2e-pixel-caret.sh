#!/usr/bin/env bash
# End-to-end check of the pixel caret locator in the running app, with no keystrokes: opens
# a copy of a fixture in APP, runs Foretype restricted to APP, moves the caret with
# Accessibility (`ftdrive caret`) to line ends and along a line, and screenshots the window
# region (the overlay is its own window, so `screencapture -R` is used) after each step.
#
# Safety: FORETYPE_ONLY_APPS=BUNDLE_ID; waits for an unlocked screen and $IDLE s (default 20)
# of user inactivity; every step aborts if APP or the test document leaves the front or the
# user touches the keyboard or mouse. The document is closed unmodified, APP quit if this
# script started it, and the copy deleted.
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-pixel-caret.sh [APP] [BUNDLE_ID] [FIXTURE]
#        (default: LibreOffice org.libreoffice.script scripts/fixtures/caret-lines.rtf)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
APP="${1:-LibreOffice}"
BUNDLE="${2:-org.libreoffice.script}"
FIXTURE="${3:-$ROOT/scripts/fixtures/caret-lines.rtf}"
TEXT="${FIXTURE%.*}.txt"   # the same lines as plain text, for caret positions
OUT="${OUT:-$ROOT/build/e2e-pixel}"
IDLE="${IDLE:-20}"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE" || exit 1
mkdir -p "$OUT"
LOG="$OUT/foretype.log"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/foretype-pixel.XXXXXX")"
STEM="foretype-pixel-$(date +%s)"
DOC="$TMP/$STEM.${FIXTURE##*.}"
cp "$FIXTURE" "$DOC"
PID=""
FT=""
WAS_RUNNING=0
app_pid() { pgrep -f "/$APP.app/Contents/MacOS/" | head -1; }
cleanup() {
  [ -n "$FT" ] && kill "$FT" 2>/dev/null
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
locked() { ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q true; }
echo "waiting for an unlocked screen and ${IDLE}s of user inactivity..."
until ! locked && [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done
[ -n "$(app_pid)" ] && WAS_RUNNING=1
START=$(date +%s)
user_back() { [ "$(idle)" -lt $(( $(date +%s) - START )) ]; }

FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS="$BUNDLE" "$BIN" >"$LOG" 2>&1 &
FT=$!
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
grep -q "engine ready" "$LOG" || { echo "engine did not start"; exit 1; }

# PRELAUNCH=1: start APP without a document first, so its accessibility is already on when
# the document opens (LibreOffice reports no focused element for a document it opened
# before any Accessibility client asked).
if [ "${PRELAUNCH:-0}" = 1 ] && [ "$WAS_RUNNING" = 0 ]; then
  open -a "$APP"
  sleep 6
fi
echo "opening $STEM in $APP at $(date +%T)"
open -a "$APP" "$DOC"
for _ in $(seq 120); do
  P="$("$DRIVE" front-pid)"
  case "$("$DRIVE" title "$P" 2>/dev/null)" in *"$STEM"*) PID="$P"; break ;; esac
  sleep 0.25
done
[ -n "$PID" ] || { echo "the test document did not come to the front"; exit 1; }
sleep 2

# Index just past the last character of each line (UTF-16 = bytes for this ASCII text).
ENDS=($(awk '{ pos += length($0); print pos; pos += 1 }' "$TEXT"))
mark() { echo "=== $1" >>"$LOG"; echo "=== $1"; }
step() {
  if user_back; then echo "ABORT: the user is active again"; exit 3; fi
  "$DRIVE" caret "$PID" "$STEM" "$1" || { echo "ABORT: $APP or the test document left the front"; exit 3; }
}
shot() {
  local r; r="$("$DRIVE" frame "$PID")" || return
  screencapture -x -R"$r" "$OUT/$1.png" 2>/dev/null || true
}

mark "1 end of line 1 (new field: mirror card, then blink)"
step "${ENDS[0]}"; sleep 3; shot 1-line1-end
mark "2 middle of line 3 (another line: blink)"
step $((ENDS[2] - 22)); sleep 3
mark "3 end of line 3 (same line: advance, then verify)"
step "${ENDS[2]}"; sleep 0.2; shot 2-line3-end-advanced; sleep 2; shot 3-line3-end-verified
mark "4 end of line 6"
step "${ENDS[5]}"; sleep 3; shot 4-line6-end
mark "done"
echo "--- foretype caret events:"
grep -E "pixel caret|caret=|^===" "$LOG" | grep -v " pending" | tail -40
echo "screenshots in $OUT"
