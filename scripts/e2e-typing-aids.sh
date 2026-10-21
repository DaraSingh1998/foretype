#!/usr/bin/env bash
# End-to-end check of the typing aids in a new, unsaved TextEdit document: an emoji
# shortcode, autocorrect, the typo gate and a mid-line suggestion. Prints PASS/FAIL per step.
#
# Safety as in e2e-textedit.sh: Foretype runs with FORETYPE_ONLY_APPS=com.apple.TextEdit, the
# test waits until the user has been idle for $IDLE seconds, every typing step aborts if focus
# leaves TextEdit, and the document is closed without saving. Mid-line is switched on in the
# development binary's own defaults domain ("Foretype", not the app's) and off again after.
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-typing-aids.sh [outdir]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
OUT="${1:-$ROOT/build/e2e-aids}"
IDLE="${IDLE:-20}"
mkdir -p "$OUT"
LOG="$OUT/foretype.log"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
[ -x "$DRIVE" ] || swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE"

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
echo "waiting for ${IDLE}s of user inactivity..."
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done

defaults write Foretype midLine -bool true
FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS=com.apple.TextEdit "$BIN" >"$LOG" 2>&1 &
FT=$!
cleanup() {
  osascript -e 'tell application "TextEdit" to if (count of documents) > 0 then close document 1 saving no' >/dev/null 2>&1
  kill "$FT" 2>/dev/null
  defaults delete Foretype midLine 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
grep -q "engine ready" "$LOG" || { echo "engine did not start"; exit 1; }

osascript -e 'tell application "TextEdit"' -e 'activate' -e 'make new document' \
  -e 'set text of document 1 to "Notes from the planning call."' -e 'end tell' >/dev/null
open -a TextEdit
for _ in $(seq 25); do [ "$("$DRIVE" front)" = "com.apple.TextEdit" ] && break; sleep 0.2; done
sleep 0.8
front() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$("$DRIVE" front)" = "com.apple.TextEdit" ] && return 0; sleep 0.2; done
  echo "ABORT: focus left TextEdit"; exit 3
}
TE=$("$DRIVE" front-pid)
mark() { echo "=== $1" >>"$LOG"; echo "=== $1"; }
since() { awk -v m="=== $1" 'f; $0 == m {f=1}' "$LOG"; }
doc() { osascript -e 'tell application "TextEdit" to get text of document 1'; }
shot() {
  local b; b=$(osascript -e 'tell application "TextEdit" to get bounds of window 1' | tr -d ' ')
  IFS=, read -r x1 y1 x2 y2 <<<"$b"
  screencapture -x -R"$x1,$y1,$((x2 - x1)),$((y2 - y1 + 60))" "$OUT/$1.png" 2>/dev/null || true
}
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi; }
FAILED=0
front; "$DRIVE" key cmd-down; sleep 0.6

mark "1 emoji"
front; "$DRIVE" type " Great news :tad" 110 || exit 3
sleep 1.0; shot 1-emoji
front; "$DRIVE" key tab; sleep 0.8
check "emoji suggested" 'since "1 emoji" | grep -q " emoji "'
check "Tab replaced :tad with the emoji" 'doc | grep -q "Great news 🎉"'

mark "2 autocorrect"
front; "$DRIVE" type " I will recieve " 110 || exit 3
sleep 1.2; shot 2-autocorrect
front; "$DRIVE" key tab; sleep 0.8
check "correction suggested" 'since "2 autocorrect" | grep -q " autocorrect "'
check "Tab replaced recieve" 'doc | grep -q "I will receive" && ! doc | grep -q recieve'

mark "3 typo gate"
front; "$DRIVE" type " zqxwv" 110 || exit 3
sleep 1.0
check "no suggestion for zqxwv (last event a policy hide)" 'since "3 typo gate" | grep -E "^\[ " | grep -v pending | tail -1 | grep -q " policy "'

mark "4 mid-line"
# A word cut out of a sentence: the caret goes after "should" (no keystrokes) and the
# first letter of the missing word is typed.
osascript -e 'tell application "TextEdit" to set text of document 1 to "We should the meeting to Thursday."' >/dev/null
sleep 0.5
front; "$DRIVE" caret "$TE" "Untitled" 9 || echo "could not place the caret"
sleep 0.5
front; "$DRIVE" type " m" 150 || exit 3
sleep 1.5; shot 4-midline
check "mid-line suggestion shown" 'since "4 mid-line" | grep -E " model [0-9]+ms" | grep -vq -- "-> \"\"$"'
front; "$DRIVE" key tab; sleep 0.8

doc >"$OUT/result.txt"
echo "--- document:"; cat "$OUT/result.txt"
echo "--- events:"; grep -E "^\[ |^===" "$LOG" | grep -v " pending" | tail -40
exit "$FAILED"
