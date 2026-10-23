#!/usr/bin/env bash
# No-keystroke end-to-end check of text from other apps (D42): one TextEdit document with
# known content, a second one focused beside it, Foretype restricted to TextEdit; the debug
# log must show the first document's passage in the prompt's other-apps section.
#
# Safety: FORETYPE_ONLY_APPS=com.apple.TextEdit, and TextEdit must not be running before the
# test (its other documents would be read too). Waits for $IDLE seconds of user inactivity
# before taking focus. Types nothing: the caret is put at the end of the draft through
# Accessibility (`ftdrive caret`). Both documents are files in the output folder; they are
# closed unchanged at the end and TextEdit is quit. FORETYPE_OTHER_APPS=1 turns the feature
# on for this process only (the saved setting is not touched).
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-context.sh [outdir]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
OUT="${1:-$ROOT/build/e2e-context}"
IDLE="${IDLE:-20}"
mkdir -p "$OUT" "$ROOT/build"
OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/foretype.log"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
[ -n "${FORETYPE_ABOUT_YOU+set}" ] || export FORETYPE_ABOUT_YOU='{}'
[ -x "$DRIVE" ] || swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE" || exit 1
if pgrep -x TextEdit >/dev/null; then
  echo "TextEdit is running: quit it first (Foretype would read its other documents too)"
  exit 2
fi

SOURCE="$OUT/ctx-source.txt"
DRAFT="$OUT/ctx-draft.txt"
cat >"$SOURCE" <<'TEXT'
Ferry timetable, Zanzibar crossing
The morning ferry leaves Stone Town pier 9 at 07:45 and arrives in Dar es Salaam at 09:30.
The afternoon ferry leaves at 15:20 from the same pier.
Tickets cost 35 dollars in economy and 50 dollars in business class.
TEXT
printf 'Hi Sam,\n\nAbout the trip: the morning ferry leaves Stone Town pier' >"$DRAFT"
DRAFT_LEN=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read().encode("utf-16-le")) // 2)' "$DRAFT")

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
echo "waiting for ${IDLE}s of user inactivity..."
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done
echo "user idle; starting at $(date +%T)"

TE=""
FT=""
cleanup() {
  if [ -n "$TE" ]; then
    "$DRIVE" close "$TE" ctx-draft >/dev/null 2>&1
    "$DRIVE" close "$TE" ctx-source >/dev/null 2>&1
    sleep 0.5
    "$DRIVE" quit "$TE" >/dev/null 2>&1
  fi
  [ -n "$FT" ] && kill "$FT" 2>/dev/null
}
trap cleanup EXIT

# The documents first, side by side; TextEdit must show nothing else before Foretype starts
# (no restored windows: -ApplePersistenceIgnoreState).
open -a TextEdit "$SOURCE" --args -ApplePersistenceIgnoreState YES
for _ in $(seq 25); do TE=$(pgrep -x TextEdit) && [ -n "$TE" ] && "$DRIVE" title "$TE" 2>/dev/null | grep -q ctx-source && break; sleep 0.2; done
[ -n "$TE" ] || { echo "TextEdit did not open"; exit 1; }
osascript -e 'tell application "TextEdit" to set bounds of window 1 to {40, 80, 640, 640}' >/dev/null 2>&1
open -a TextEdit "$DRAFT"
for _ in $(seq 25); do "$DRIVE" title "$TE" 2>/dev/null | grep -q ctx-draft && break; sleep 0.2; done
osascript -e 'tell application "TextEdit" to set bounds of window 1 to {660, 80, 1260, 640}' >/dev/null 2>&1
others=$("$DRIVE" windows com.apple.TextEdit | grep '^window: ' | grep -v -e ctx-source -e ctx-draft)
if [ -n "$others" ]; then
  echo "ABORT: TextEdit shows other windows too:"; echo "$others"; exit 2
fi

FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS=com.apple.TextEdit FORETYPE_OTHER_APPS=1 "$BIN" >"$LOG" 2>&1 &
FT=$!
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
grep -q "engine ready" "$LOG" || { echo "engine did not start"; exit 1; }
open -a TextEdit
sleep 0.8
"$DRIVE" caret "$TE" ctx-draft "$DRAFT_LEN" || { echo "ABORT: could not place the caret (focus left TextEdit?)"; exit 3; }

ok=""
for _ in $(seq 30); do
  if grep -E "other apps section:.*ctx-source.*(morning ferry|Zanzibar)" "$LOG" >/dev/null; then ok=1; break; fi
  sleep 0.5
done
echo "--- foretype (context lines):"
grep -E "context:|other apps|ctx-draft|ctx-source| model " "$LOG" | grep -v " pending" | tail -20
if [ -n "$ok" ]; then
  echo "PASS: the other document's passage reached the prompt"
else
  echo "FAIL: no other-apps section with the source document (log: $LOG)"
  exit 1
fi
