#!/usr/bin/env bash
# Which Accessibility call makes a fresh Chrome expose its focused web element? For each
# trigger, starts a separate Chrome process with a throwaway profile (your own Chrome and
# profile are not touched), raises it with the fixture textarea focused, applies the trigger
# through chrome_triggers (reads only that pid), then quits that Chrome.
#
#   TRIGGERS="none enhanced" tools/spike/probe/run_chrome_triggers.sh
#
# Nothing is typed. Each run raises the test Chrome for ~10 s, then gives focus back; leave
# the keyboard and mouse alone meanwhile. The binary is not bundled: run from a terminal it
# inherits that terminal's Accessibility grant. Output: results/probe/chrome-triggers.jsonl.
#
# Extra runs: "refocus" and "refocus+observer" load the fixture with #refocus (the page moves
# focus between two textareas every 1.5 s); "flag" starts Chrome with
# --force-renderer-accessibility and only reads.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../../.."
OUT="${OUT_DIR:-$HERE/../results/probe}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BIN="$ROOT/build/chrome_triggers"
DRIVE="$ROOT/build/ftdrive"
SECONDS_PER_RUN="${SECONDS_PER_RUN:-10}"
TRIGGERS="${TRIGGERS:-none observer window walk enhanced enhanced-blip manual observer+enhanced refocus refocus+observer flag}"
mkdir -p "$OUT" "$ROOT/build"
swiftc -O "$HERE/chrome_triggers.swift" -o "$BIN"
[[ -x "$DRIVE" ]] || swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE"
LOG="$OUT/chrome-triggers.jsonl"
: >"$LOG"
others=()
for app in Cotypist Raycast Alfred BetterTouchTool Rectangle Magnet "Keyboard Maestro Engine" TextExpander; do
  pgrep -xq "$app" && others+=("$app")
done
echo "{\"event\":\"env\",\"chrome\":\"$("$CHROME" --version)\",\"otherAXClients\":\"${others[*]:-}\"}" >>"$LOG"
BEFORE="$("$DRIVE" front-pid)"

for trig in $TRIGGERS; do
  page="file://$HERE/fixtures/testpage.html"; flags=(); probe="$trig"
  case "$trig" in
    refocus) page+="#refocus"; probe=none ;;
    refocus+observer) page+="#refocus"; probe=observer ;;
    flag) flags=(--force-renderer-accessibility); probe=none ;;
  esac
  PROFILE="$(mktemp -d -t foretype-chrome)"
  "$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check ${flags[@]+"${flags[@]}"} \
    --new-window "$page" >/dev/null 2>&1 &
  PID=$!
  sleep "${SETTLE:-4}"
  "$DRIVE" raise "$PID" || echo "warning: could not raise the test Chrome" >&2
  sleep 1
  echo "{\"event\":\"run\",\"run\":\"$trig\",\"probe\":\"$probe\",\"page\":\"${page##*/}\"}" >>"$LOG"
  "$BIN" "$PID" "$probe" "$SECONDS_PER_RUN" >>"$LOG" || true
  kill "$PID" 2>/dev/null || true
  "$DRIVE" raise "$BEFORE" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  rm -rf "$PROFILE"
  grep '"summary"' "$LOG" | tail -1
done
echo "done: $LOG"
