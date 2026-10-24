#!/usr/bin/env bash
# End-to-end check of word alternatives (D50) in a new, unsaved TextEdit document: the card
# after a typing pause, Option+1 taking an alternative's next word (Tab going on with it),
# Option+0 opening and closing the card, and Esc closing only the card.
#
# Safety as in e2e-textedit.sh: Foretype runs with FORETYPE_ONLY_APPS=com.apple.TextEdit, the
# test waits until the user has been idle for $IDLE seconds before taking focus, and every
# typing step aborts if focus leaves TextEdit. It types synthetic keys: tell the user first.
# Show Alternatives is turned on for this process only (-alternatives YES); the stored
# setting is left as it is. Needs mains power (the card shows by itself only with the beam).
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-alternatives.sh [outdir]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
OUT="${1:-$ROOT/build/e2e-alternatives}"
IDLE="${IDLE:-20}"
mkdir -p "$OUT"
LOG="$OUT/foretype.log"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
[ -n "${FORETYPE_ABOUT_YOU+set}" ] || export FORETYPE_ABOUT_YOU='{}'
[ "$DRIVE" -nt "$ROOT/scripts/ftdrive.swift" ] || swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE" || exit 1

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
echo "waiting for ${IDLE}s of user inactivity..."
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done
echo "user idle; starting at $(date +%T)"

FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS=com.apple.TextEdit "$BIN" -alternatives YES -personalize NO >"$LOG" 2>&1 &
FT=$!
cleanup() {
  osascript -e 'tell application "TextEdit" to if (count of documents) > 0 then close document 1 saving no' >/dev/null 2>&1
  kill "$FT" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
grep -q "engine ready" "$LOG" || { echo "engine did not start"; exit 1; }

osascript -e 'tell application "TextEdit"' -e 'activate' -e 'make new document' \
  -e 'set text of document 1 to "Hi Priya,"' -e 'end tell' >/dev/null
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
  # The card can sit under the window's last line: take 120 pt below it too.
  screencapture -x -R"$x1,$y1,$((x2 - x1)),$((y2 - y1 + 120))" "$OUT/$1.png" 2>/dev/null || true
}
front; "$DRIVE" key cmd-down; sleep 0.6

mark "1 type, pause: the card shows by itself"
front; "$DRIVE" type $'\n\nThanks for sending the' 110 || exit 3
sleep 2.0; shot 1-card
mark "2 Option+1 takes the first alternative's next word"
front; "$DRIVE" key opt-1; sleep 0.8; shot 2-after-option-1
mark "3 Tab goes on with it"
front; "$DRIVE" key tab; sleep 0.8
mark "4 Option+0 right after typing shows the card at once (or asks)"
front; "$DRIVE" type " and I will" 110 || exit 3
sleep 0.3; front; "$DRIVE" key opt-0; sleep 0.6; shot 4-option-0
mark "5 Option+0 again closes it"
front; "$DRIVE" key opt-0; sleep 0.5; shot 5-closed
mark "6 Option+0, then Esc closes only the card; a second Esc dismisses"
front; "$DRIVE" key opt-0; sleep 0.6; front; "$DRIVE" key esc; sleep 0.5; shot 6-esc-card
front; "$DRIVE" key esc; sleep 0.5

osascript -e 'tell application "TextEdit" to get text of document 1' >"$OUT/result.txt"
echo "--- document:"; cat "$OUT/result.txt"; echo
echo "--- foretype events:"; grep -E "^\[|^===" "$LOG" | grep -E "===|alternative|accept|Esc|model|typeThrough|cache" | tail -60
