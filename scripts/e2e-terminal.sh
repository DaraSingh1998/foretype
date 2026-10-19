#!/usr/bin/env bash
# End-to-end test of terminal behaviour in a new Terminal window running `tee`, so nothing
# typed ever reaches a shell and every entered line lands in a file we can check.
# The window is opened from a .command file (no AppleScript automation permission needed).
# Checks: no suggestions on an ordinary line, the force hotkey (current line only),
# suggestions on an AI-agent prompt line ("> "), and the snooze hotkey.
#
# Safety: FORETYPE_ONLY_APPS=com.apple.Terminal, waits for the user to be idle, typing
# pauses/aborts if focus leaves Terminal, and nothing is typed until tee is confirmed running
# on a fresh tty.
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-terminal.sh [outdir]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
OUT="${1:-$ROOT/build/e2e-terminal}"
IDLE="${IDLE:-20}"
mkdir -p "$OUT"
LOG="$OUT/foretype.log"
LINES="$OUT/typed-lines.txt"
PIDFILE="$OUT/tee.pid"
CMD="$OUT/foretype-e2e.command"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
rm -f "$LINES" "$PIDFILE"
cat >"$CMD" <<SH
#!/bin/sh
clear
echo \$\$ > "$PIDFILE"
exec tee "$LINES"
SH
chmod +x "$CMD"

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
until [ "$(idle)" -ge "$IDLE" ]; do sleep 1; done
echo "user idle; starting at $(date +%T)"

FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS=com.apple.Terminal "$BIN" >"$LOG" 2>&1 &
FT=$!
cleanup() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
  kill "$FT" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done

open -a Terminal "$CMD"
for _ in $(seq 50); do [ -f "$PIDFILE" ] && break; sleep 0.2; done
TEE=$(cat "$PIDFILE" 2>/dev/null)
ps -o command= -p "${TEE:-0}" 2>/dev/null | grep -q "^tee " || { echo "ABORT: tee is not running in the new window"; exit 4; }
for _ in $(seq 25); do [ "$("$DRIVE" front)" = "com.apple.Terminal" ] && break; sleep 0.2; done
sleep 1.2
front() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$("$DRIVE" front)" = "com.apple.Terminal" ] && return 0; sleep 0.2; done
  echo "ABORT: focus left Terminal"; exit 3
}
mark() { echo "=== $1" >>"$LOG"; echo "=== $1"; }

mark "1 ordinary line: expect no suggestion"
front; "$DRIVE" type "echo the deployment finished without" 90 || exit 3
sleep 1.0
mark "2 force hotkey: expect a suggestion, then Tab"
front; "$DRIVE" key force; sleep 1.2; front; "$DRIVE" key tab; sleep 0.6
front; "$DRIVE" key return; sleep 0.4
mark "3 agent prompt line: expect suggestions, then Tab"
front; "$DRIVE" type "> Please add a unit test for the" 90 || exit 3
sleep 1.2; front; "$DRIVE" key tab; sleep 0.6
mark "4 snooze hotkey: expect no suggestions afterwards"
front; "$DRIVE" key snooze; sleep 0.4
front; "$DRIVE" type " and also" 90 || exit 3
sleep 1.0; front; "$DRIVE" key return; sleep 0.5

echo "--- lines entered (tee):"; cat "$LINES"
echo "--- foretype events:"; grep -E "^===|policy|model|accept|force|snoozed|cache" "$LOG" | grep -v " pending" | cut -c1-150 | tail -30
