#!/usr/bin/env bash
# No-keystroke live check of What Foretype Sees (D48): two TextEdit documents side by side,
# the dev bundle restricted to TextEdit; the window (opened by FORETYPE_CONTEXT_REPORT,
# without taking focus) must list the other document's window and its passage in the last
# prompt. $OUT/report is what it showed, $OUT/report.png the window.
#
# Safety as in e2e-context.sh: FORETYPE_ONLY_APPS=com.apple.TextEdit, TextEdit must not be
# running, waits for $IDLE seconds of user inactivity before taking focus, types nothing
# (caret moves through Accessibility), closes both documents unchanged and quits TextEdit
# and the dev build. FORETYPE_OTHER_APPS=1 and `-personalize NO` (no Keychain prompt for the
# dev signature) apply to this process only; the stored settings are not touched.
#
# usage: scripts/e2e-context-view.sh [outdir]   (after scripts/build-mac.sh)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Foretype.app"
DRIVE="$ROOT/build/ftdrive"
OUT="${1:-$ROOT/build/e2e-context-view}"
IDLE="${IDLE:-20}"
mkdir -p "$OUT" "$ROOT/build"
OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/foretype.log"
rm -f "$OUT/report" "$OUT/report.png" "$LOG"
[ -x "$APP/Contents/MacOS/Foretype" ] || { echo "build it first: scripts/build-mac.sh"; exit 1; }
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
LEN=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read().encode("utf-16-le")) // 2)' "$DRAFT")

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
echo "waiting for ${IDLE}s of user inactivity..."
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done
echo "user idle; starting at $(date +%T)"

TE=""
FT=""
cleanup() {
  [ -n "$FT" ] && kill "$FT" 2>/dev/null
  if [ -n "$TE" ]; then
    "$DRIVE" close "$TE" ctx-draft >/dev/null 2>&1
    "$DRIVE" close "$TE" ctx-source >/dev/null 2>&1
    sleep 0.5
    "$DRIVE" quit "$TE" >/dev/null 2>&1
  fi
  sleep 1
  if pgrep -f "$APP/Contents/MacOS/Foretype" >/dev/null; then pkill -f "$APP/Contents/MacOS/Foretype"; fi
}
trap cleanup EXIT

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

open -n --stdout "$LOG" --stderr "$LOG" --env FORETYPE_ONLY_APPS=com.apple.TextEdit --env FORETYPE_OTHER_APPS=1 \
  --env FORETYPE_DEBUG=1 --env 'FORETYPE_ABOUT_YOU={}' --env FORETYPE_CONTEXT_REPORT="$OUT/report" \
  "$APP" --args -personalize NO
for _ in $(seq 20); do FT=$(pgrep -f "$APP/Contents/MacOS/Foretype" | head -1); [ -n "$FT" ] && break; sleep 0.25; done
[ -n "$FT" ] || { echo "the dev build did not start"; exit 1; }
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
grep -q "engine ready" "$LOG" || { echo "engine did not start (Accessibility for $APP?)"; tail -5 "$LOG"; exit 1; }
open -a TextEdit
sleep 0.8
"$DRIVE" caret "$TE" ctx-draft "$LEN" || { echo "ABORT: could not place the caret (focus left TextEdit?)"; exit 3; }

ok=""
for i in $(seq 40); do
  sleep 1
  if grep -q "^passage: .*ctx-source" "$OUT/report" 2>/dev/null && grep -q "^window: .*ctx-source" "$OUT/report"; then ok=1; break; fi
  # Every 6 s a caret move makes a new request (nothing is typed).
  if [ $((i % 6)) = 0 ]; then
    [ "$("$DRIVE" front)" = com.apple.TextEdit ] || { echo "ABORT: focus left TextEdit"; exit 3; }
    "$DRIVE" caret "$TE" ctx-draft $((LEN - 1)) >/dev/null 2>&1
    sleep 0.4
    "$DRIVE" caret "$TE" ctx-draft "$LEN" >/dev/null 2>&1
  fi
done
sleep 2.5
echo "--- What Foretype Sees ($OUT/report, picture: report.png):"
cat "$OUT/report" 2>/dev/null
if [ -n "$ok" ]; then
  echo "PASS: the window lists the other document and its passage in the last prompt"
else
  echo "FAIL: the other document's passage isn't in the view (log: $LOG)"
  exit 1
fi
