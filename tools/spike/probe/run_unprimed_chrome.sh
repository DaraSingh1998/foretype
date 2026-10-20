#!/usr/bin/env bash
# Unprimed-Chrome baseline (the Phase 0 gap): what Chrome's Accessibility tree reports for a
# focused textarea before anyone sets AXEnhancedUserInterface, and after the probe sets it.
#
# In the Phase 0 run Chrome was already primed by another Accessibility client, so the
# "no bounds and no font until primed" failure was only reproduced in Edge. This starts a
# separate Chrome process with a throwaway profile (your own Chrome windows and profile are
# not touched), reads the field once unprimed, once primed, then quits that process.
#
# Before running:
#   1. tools/spike/probe/make_app.sh, then grant Accessibility to bundle/AXProbe.app
#      (System Settings → Privacy & Security → Accessibility; re-grant after every rebuild).
#   2. Quit the other Accessibility clients that prime Chromium (Cotypist, Raycast, and
#      similar); the script lists the ones it sees and stops unless FORCE=1.
#   3. Leave the keyboard and mouse alone for ~20 seconds. Nothing is typed, and the probe
#      reads only the test Chrome's process (--pid), whichever app is in front.
#
# Output: results/probe/chrome-unprimed.once.jsonl and chrome-primed.once.jsonl.
#
# Superseded: the primed read comes 0.5 s after the flag is set and the probe clears it on
# exit, but Chrome turns on web content only after the flag has stayed set for 2 s, so this
# always reads noValue. run_chrome_triggers.sh measures it properly (docs/MEASUREMENTS.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${AXPROBE_BIN:-$HERE/bundle/AXProbe.app/Contents/MacOS/axprobe}"
OUT="${OUT_DIR:-$HERE/../results/probe}"
PAGE="file://$HERE/fixtures/testpage.html"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$BIN" ]] || { echo "missing $BIN: run make_app.sh and grant it Accessibility" >&2; exit 1; }
[[ -x "$CHROME" ]] || { echo "Google Chrome not installed" >&2; exit 1; }
mkdir -p "$OUT"

others=()
for app in Cotypist Raycast Alfred BetterTouchTool Rectangle Magnet "Keyboard Maestro Engine" TextExpander; do
  pgrep -xq "$app" && others+=("$app")
done
if [[ ${#others[@]} -gt 0 && "${FORCE:-0}" != 1 ]]; then
  echo "quit these first (they may prime Chrome): ${others[*]}  (FORCE=1 to run anyway)" >&2
  exit 1
fi

DRIVE="$HERE/../../../build/ftdrive"   # scripts/ftdrive.swift (raise / front-pid)
[[ -x "$DRIVE" ]] || swiftc -O "$HERE/../../../scripts/ftdrive.swift" -o "$DRIVE"
BEFORE="$("$DRIVE" front-pid)"
PROFILE="$(mktemp -d -t foretype-chrome)"
"$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check --new-window "$PAGE" >/dev/null 2>&1 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; "$DRIVE" raise "$BEFORE" 2>/dev/null || true; sleep 1; rm -rf "$PROFILE"; }
trap cleanup EXIT
sleep "${SETTLE:-4}"
# Chrome only has a focused element while its window is key; a process started from a shell
# isn't activated (cooperative activation), so raise it, and give focus back afterwards.
"$DRIVE" raise "$PID" || echo "warning: could not raise the test Chrome" >&2
sleep 1

# --pid: read only the test Chrome, even if another app is frontmost (never the user's apps).
"$BIN" --once --pid "$PID" >"$OUT/chrome-unprimed.once.jsonl" || true
"$BIN" --once --chromium-ax --pid "$PID" >"$OUT/chrome-primed.once.jsonl" || true
grep -q "\"pid\":$PID" "$OUT/chrome-unprimed.once.jsonl" || { echo "probe did not read the test Chrome" >&2; exit 1; }
echo "done: $OUT/chrome-unprimed.once.jsonl, $OUT/chrome-primed.once.jsonl"
