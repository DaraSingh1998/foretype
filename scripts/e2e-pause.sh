#!/usr/bin/env bash
# Pausing, end to end, without a single keystroke: the dev bundle (build/Foretype.app, which
# has the foretype:// URL scheme) runs restricted to TextEdit, a test document is opened, and
# the caret is moved by Accessibility (ftdrive caret) to make Foretype read the field.
#
#   1 running: caret moves produce snapshots (suggestion lines in the log)
#   2 foretype://pause?minutes=10: the core frees the model; caret moves, an app switch and
#     a wait produce nothing at all (no suggestion, priming or screen line in the log)
#   3 foretype://resume: snapshots again, the model loads on the next suggestion
#   4 foretype://pause?minutes=0.1: resumes by itself after 6 s
#
# For each of idle-running and paused it samples the process for SAMPLE seconds: CPU time
# used, idle wakeups (top's IDLEW) and resident memory. TYPE=1 adds a typing sample first:
# synthetic keystrokes at the end of the test document (the only phase that types).
#
# Safety: FORETYPE_ONLY_APPS=com.apple.TextEdit; waits until the user has been idle for
# $IDLE seconds before taking focus; aborts if the user comes back or TextEdit leaves the
# front. The dev bundle shares its settings with an installed Foretype (same bundle ID), so it
# only ever pauses for a set time and resumes when done. The test document is closed at the
# end and focus goes back to the app that was in front.
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-pause.sh [outdir]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Foretype.app"
DRIVE="$ROOT/build/ftdrive"
OUT="${1:-$ROOT/build/e2e-pause}"
IDLE="${IDLE:-10}"
SAMPLE="${SAMPLE:-20}"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
[[ -d "$APP" ]] || { echo "build the bundle first: scripts/build-mac.sh"; exit 1; }
mkdir -p "$OUT"
LOG="$OUT/foretype.log"
DOC="$OUT/pause-test.txt"
TITLE="pause-test.txt"
printf 'Thanks for sending the planning notes. I read them twice and I think we are closer to agreement than it felt on Monday. I will send the' >"$DOC"
[[ -x "$DRIVE" ]] || swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE" || exit 1

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
echo "waiting for ${IDLE}s of user inactivity..."
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done

BEFORE="$("$DRIVE" front-pid)"
: >"$LOG"
open -n -g --stderr "$LOG" --env FORETYPE_DEBUG=1 --env FORETYPE_ONLY_APPS=com.apple.TextEdit \
  --env FORETYPE_MODEL="$FORETYPE_MODEL" --env 'FORETYPE_ABOUT_YOU={}' "$APP"
FT=""
for _ in $(seq 20); do FT="$(pgrep -n -f "$APP/Contents/MacOS/Foretype")" && break; sleep 0.3; done
[ -n "$FT" ] || { echo "dev bundle did not start"; exit 1; }
TE=""
url() {
  # `open -a` would launch the bundle unrestricted if it had quit: only while it runs.
  kill -0 "$FT" 2>/dev/null || { echo "ABORT: Foretype quit"; exit 1; }
  echo "=== url $1" >>"$LOG"
  open -g -a "$APP" "$1"
}
cleanup() {
  kill -0 "$FT" 2>/dev/null && open -g -a "$APP" "foretype://resume" && sleep 1
  kill "$FT" 2>/dev/null
  [ -n "$TE" ] && "$DRIVE" close "$TE" "$TITLE" 2>/dev/null
  "$DRIVE" raise "$BEFORE" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
grep -q "engine ready" "$LOG" || { echo "engine did not start (Accessibility granted to build/Foretype.app?)"; exit 1; }

open -a TextEdit "$DOC"
for _ in $(seq 25); do [ "$("$DRIVE" front)" = "com.apple.TextEdit" ] && break; sleep 0.2; done
TE="$("$DRIVE" front-pid)"
[ "$("$DRIVE" front)" = "com.apple.TextEdit" ] || { echo "could not bring TextEdit to the front"; exit 1; }
# The document's window can come up after TextEdit is in front: wait until the caret can be
# put at its end (typing must not start anywhere else).
LEN=$(wc -c <"$DOC" | tr -d ' ')
for _ in $(seq 25); do "$DRIVE" caret "$TE" "$TITLE" "$LEN" 2>/dev/null && break; sleep 0.2; done
"$DRIVE" caret "$TE" "$TITLE" "$LEN" || { echo "the test document did not open"; exit 1; }
sleep 0.5
START=$(date +%s)
check() {
  [ "$(idle)" -lt $(( $(date +%s) - START )) ] && { echo "ABORT: the user is active again"; exit 3; }
  [ "$("$DRIVE" front)" = "com.apple.TextEdit" ] || { echo "ABORT: TextEdit left the front"; exit 3; }
}
mark() { echo "=== $1" >>"$LOG"; echo "=== $1"; }
# Lines after the last mark matching a pattern.
since() { awk -v m="=== $1" 'index($0, m) == 1 { on = 1; next } on' "$LOG" | grep -cE "$2"; }
moves() {
  for pos in $((LEN - 4)) $((LEN - 30)) "$LEN" $((LEN - 60)) "$LEN"; do
    check; "$DRIVE" caret "$TE" "$TITLE" "$pos" || true; sleep 0.8
  done
}
sample() {
  local t0 t1 w0 w1
  t0=$(ps -o time= -p "$FT" | awk -F'[:.]' '{print ($1 * 60 + $2) * 100 + $3}')
  read -r w0 w1 < <(top -l 2 -s "$SAMPLE" -pid "$FT" -stats pid,idlew | awk -v p="$FT" '$1 == p { gsub(/\+/, "", $2); v[n++] = $2 } END { print v[0], v[1] }')
  t1=$(ps -o time= -p "$FT" | awk -F'[:.]' '{print ($1 * 60 + $2) * 100 + $3}')
  printf '%s: cpu %d ms in %ds, %s idle wakeups (%.1f/s), rss %d MB\n' "$1" $(( (t1 - t0) * 10 )) "$SAMPLE" \
    $(( w1 - w0 )) "$(echo "($w1 - $w0) / $SAMPLE" | bc -l)" $(( $(ps -o rss= -p "$FT") / 1024 )) | tee -a "$OUT/energy.txt"
}
: >"$OUT/energy.txt"
status=0
fail() { echo "FAIL: $1"; status=1; }

if [ "${TYPE:-0}" = 1 ]; then
  mark "0 typing"
  check; "$DRIVE" caret "$TE" "$TITLE" "$LEN" || { echo "ABORT: caret not at the end"; exit 3; }
  "$DRIVE" type " timeline by Friday, and we can go through the open questions on our call next week. Let me know if anything in the notes needs a closer look before then, and thanks again for pulling it together so quickly." 140 &
  TYPER=$!
  sample "typing (7 chars/s)"
  kill "$TYPER" 2>/dev/null; wait "$TYPER" 2>/dev/null
  sleep 2
  # Synthetic keystrokes count as input: idleness is measured from here on.
  START=$(date +%s)
fi

mark "1 running"
moves
n=$(since "1 running" '^\[.*\] rev [0-9]+ ')
echo "suggestion lines while running: $n"; [ "$n" -gt 0 ] || fail "no snapshots while running"
check; sample "running, idle in a field"

mark "2 paused"
url "foretype://pause?minutes=10"
for _ in $(seq 20); do grep -q "engine paused" "$LOG" && break; sleep 0.25; done
grep -q "engine paused: model unloaded" "$LOG" || fail "the core did not free the model"
moves
open -a TextEdit "$DOC"; sleep 1
check; sample "paused"
n=$(since "2 paused" ' rev [0-9]+ |primed |screen: |pixel caret|tracker started')
echo "activity lines while paused: $n"; [ "$n" -eq 0 ] || fail "work while paused"

mark "3 resumed"
url "foretype://resume"
for _ in $(seq 20); do grep -q "paused: false" "$LOG" && break; sleep 0.25; done
moves
n=$(since "3 resumed" '^\[.*\] rev [0-9]+ ')
echo "suggestion lines after resume: $n"; [ "$n" -gt 0 ] || fail "no snapshots after resume"
since "3 resumed" "engine (loading|ready)" >/dev/null || fail "the model did not load again"

mark "4 timed pause"
url "foretype://pause?minutes=0.1"
sleep 1
[ "$(since "4 timed pause" 'paused: true')" -gt 0 ] || fail "timed pause did not start"
for _ in $(seq 30); do [ "$(since "4 timed pause" 'paused: false')" -gt 0 ] && break; sleep 0.5; done
[ "$(since "4 timed pause" 'paused: false')" -gt 0 ] || fail "timed pause did not end by itself"

echo "--- log (pause lines):"; grep -E "^===|paused|pause:|tracker |engine " "$LOG" | tail -40
[ $status -eq 0 ] && echo "PASS" || echo "FAILED"
exit $status
