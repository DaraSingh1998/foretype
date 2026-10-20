#!/usr/bin/env bash
# Fresh-Chrome check: a Chrome process that no Accessibility client has touched, raised with
# the fixture textarea focused, should get a suggestion within a few seconds. Chrome turns on
# its web content 2 s after Foretype sets AXEnhancedUserInterface (docs/MEASUREMENTS.md).
# Then the flag is cleared from outside, and Foretype should notice and prime again.
#
# Safety: Foretype runs with FORETYPE_ONLY_APPS set to the test Chrome's pid, so your own
# Chrome (same bundle ID) is never read or primed. Nothing is typed. The test Chrome uses a
# throwaway profile and is quit at the end; focus goes back to the app that was in front.
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-chrome-fresh.sh [outdir]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
PROBE="$ROOT/build/chrome_triggers"
OUT="${1:-$ROOT/build/e2e-chrome}"
IDLE="${IDLE:-10}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PAGE="file://$ROOT/tools/spike/probe/fixtures/testpage.html"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
mkdir -p "$OUT" "$ROOT/build"
LOG="$OUT/foretype.log"
[[ -x "$DRIVE" ]] || swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE"
swiftc -O "$ROOT/tools/spike/probe/chrome_triggers.swift" -o "$PROBE"

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
echo "waiting for ${IDLE}s of user inactivity..."
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done

BEFORE="$("$DRIVE" front-pid)"
PROFILE="$(mktemp -d -t foretype-chrome)"
"$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check --new-window "$PAGE" >/dev/null 2>&1 &
CH=$!
FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS="$CH" "$BIN" >"$LOG" 2>&1 &
FT=$!
cleanup() {
  kill "$FT" 2>/dev/null; wait "$FT" 2>/dev/null
  kill "$CH" 2>/dev/null; "$DRIVE" raise "$BEFORE" 2>/dev/null; wait "$CH" 2>/dev/null
  rm -rf "$PROFILE"
}
trap cleanup EXIT
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
grep -q "engine ready" "$LOG" || { echo "engine did not start"; exit 1; }
sleep 1

# Waits up to $1 seconds for the Nth ($2) non-empty suggestion in the test Chrome.
suggestion() {
  for _ in $(seq $(($1 * 5))); do
    [ "$(grep -cE 'Google Chrome caret=.* -> "[^"]' "$LOG")" -ge "$2" ] && return 0
    sleep 0.2
  done
  return 1
}

echo "=== raise" >>"$LOG"
"$DRIVE" raise "$CH" || { echo "could not raise the test Chrome"; exit 1; }
status=0
if suggestion 10 1; then
  # A region, not the window alone, so the overlay panel shows too.
  sleep 0.3
  read -r xy wh < <("$DRIVE" windows "$CH" | awk '/^cgwindow .* layer 0 on/ {print $6, $7; exit}')
  [ -n "${wh:-}" ] && screencapture -x -R"$xy,${wh/x/,}" "$OUT/1-fresh.png"
  echo "fresh Chrome: suggestion shown"
else
  echo "fresh Chrome: no suggestion within 10 s"; status=1
fi

echo "=== clear AXEnhancedUserInterface from outside" >>"$LOG"
n=$(grep -cE 'Google Chrome caret=.* -> "[^"]' "$LOG")
p=$(grep -c 'primed com.google.Chrome' "$LOG")
"$PROBE" "$CH" clear 6 >"$OUT/clear.jsonl"
if [ "$(grep -c 'primed com.google.Chrome' "$LOG")" -gt "$p" ] && suggestion 4 $((n + 1)); then
  echo "after clearing: primed again"
else
  echo "after clearing: not primed again"; status=1
fi

echo "--- foretype log:"
grep -E "primed|=== |Google Chrome" "$LOG" | head -30
exit $status
