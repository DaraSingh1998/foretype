#!/usr/bin/env bash
# End-to-end smoke test in a new, unsaved TextEdit document.
#
# Safety: Foretype runs with FORETYPE_ONLY_APPS=com.apple.TextEdit (no other app is read or
# intercepted), the test waits until the user has been idle for $IDLE seconds before taking
# focus, and every typing step aborts if focus leaves TextEdit.
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-textedit.sh [outdir]
#        WINDOW_BOUNDS=LEFT,TOP,RIGHT,BOTTOM puts the document window there (global points,
#        top-left origin), e.g. on a display above the main one (negative values).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
OUT="${1:-$ROOT/build/e2e}"
IDLE="${IDLE:-20}"
FIXTURE="$ROOT/scripts/fixtures/email.txt"
mkdir -p "$OUT"
LOG="$OUT/foretype.log"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
# Empty About You details: a development binary reading the saved ones would make the
# Keychain ask for the login password (the key's access list names the installed app only).
[ -n "${FORETYPE_ABOUT_YOU+set}" ] || export FORETYPE_ABOUT_YOU='{}'

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
echo "waiting for ${IDLE}s of user inactivity..."
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done
echo "user idle; starting at $(date +%T)"

FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS=com.apple.TextEdit "$BIN" >"$LOG" 2>&1 &
FT=$!
cleanup() {
  osascript -e 'tell application "TextEdit" to if (count of documents) > 0 then close document 1 saving no' >/dev/null 2>&1
  kill "$FT" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
grep -q "engine ready" "$LOG" || { echo "engine did not start"; exit 1; }

osascript -e 'tell application "TextEdit"' -e 'activate' -e 'make new document' \
  -e "set text of document 1 to (read POSIX file \"$FIXTURE\" as «class utf8»)" -e 'end tell' >/dev/null
[ -n "${WINDOW_BOUNDS:-}" ] && osascript -e "tell application \"TextEdit\" to set bounds of window 1 to {$WINDOW_BOUNDS}" >/dev/null
# AppleScript activation can be refused or delayed (cooperative activation, macOS 14+);
# LaunchServices is more reliable. Allow up to 5 s for the first focus check.
open -a TextEdit
for _ in $(seq 25); do [ "$("$DRIVE" front)" = "com.apple.TextEdit" ] && break; sleep 0.2; done
sleep 0.8
front() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$("$DRIVE" front)" = "com.apple.TextEdit" ] && return 0; sleep 0.2; done
  echo "ABORT: focus left TextEdit"; exit 3
}
mark() { echo "=== $1" >>"$LOG"; echo "=== $1"; }
shot() {
  local b; b=$(osascript -e 'tell application "TextEdit" to get bounds of window 1' | tr -d ' ')
  IFS=, read -r x1 y1 x2 y2 <<<"$b"
  screencapture -x -R"$x1,$y1,$((x2 - x1)),$((y2 - y1))" "$OUT/$1.png" 2>/dev/null || true
}
front; "$DRIVE" key cmd-down; sleep 0.6

mark "1 type, wait for suggestion"
front; "$DRIVE" type " My suggestion is that we" 110 || exit 3
sleep 1.0; shot 1-suggestion
mark "2 Tab twice (next word x2)"
front; "$DRIVE" key tab; sleep 0.6; front; "$DRIVE" key tab; sleep 0.8; shot 2-after-tabs
mark "3 accept all"
front; "$DRIVE" key accept-all; sleep 0.8
mark "4 mid-word completion"
front; "$DRIVE" type " Thanks again for the no" 110 || exit 3
sleep 1.0; shot 4-midword
front; "$DRIVE" key tab; sleep 0.8
mark "5 Esc dismisses, then Tab is a real Tab"
front; "$DRIVE" type " Let me" 110 || exit 3
sleep 1.0; front; "$DRIVE" key esc; sleep 0.5; front; "$DRIVE" key tab; sleep 0.6
mark "6 Option+Tab passes a real Tab"
front; "$DRIVE" type " know" 110 || exit 3
sleep 1.0; front; "$DRIVE" key opt-tab; sleep 0.6

osascript -e 'tell application "TextEdit" to get text of document 1' >"$OUT/result.txt"
echo "--- document tail:"; tail -c 420 "$OUT/result.txt" | cat -A | sed 's/\$$//' | tail -8
echo "--- foretype events:"; grep -E "^\[ |^===" "$LOG" | grep -v " pending" | tail -60
