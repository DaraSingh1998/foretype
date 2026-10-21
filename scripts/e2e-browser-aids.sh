#!/usr/bin/env bash
# Emoji and autocorrect accepted with Tab in a web textarea (Chrome doesn't autocorrect, so
# Foretype's own replace-on-Tab is what fixes the word), in a separate Chrome process with a
# throwaway profile. MARKERS=1 reads the field through text markers instead of ranges.
#
# Safety: FORETYPE_ONLY_APPS is the test Chrome's pid (your own Chrome is never read), every
# typing step aborts if focus leaves it, and the test Chrome is quit with its profile deleted.
#
# usage: FORETYPE_MODEL=/path/model.gguf [MARKERS=1] scripts/e2e-browser-aids.sh [outdir]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
OUT="${1:-$ROOT/build/e2e-browser}"
IDLE="${IDLE:-10}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PAGE="file://$ROOT/tools/spike/probe/fixtures/testpage.html"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
mkdir -p "$OUT"
LOG="$OUT/foretype.log"
swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE" || exit 1

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done

BEFORE="$("$DRIVE" front-pid)"
PROFILE="$(mktemp -d -t foretype-chrome)"
"$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check --new-window "$PAGE" >/dev/null 2>&1 &
CH=$!
: >"$LOG"
FORETYPE_TEXT_MARKERS="${MARKERS:-0}" FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS="$CH" "$BIN" >>"$LOG" 2>&1 &
FT=$!
cleanup() {
  kill "$FT" 2>/dev/null; wait "$FT" 2>/dev/null
  kill "$CH" 2>/dev/null; "$DRIVE" raise "$BEFORE" 2>/dev/null; wait "$CH" 2>/dev/null
  rm -rf "$PROFILE"
}
trap cleanup EXIT
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
for _ in $(seq 20); do "$DRIVE" raise "$CH" && [ "$("$DRIVE" front-pid)" = "$CH" ] && break; sleep 0.5; done
front() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$("$DRIVE" front-pid)" = "$CH" ] && return 0; sleep 0.2; done
  echo "ABORT: focus left the test Chrome"; exit 3
}
# Wait until Chrome exposes the field (primed) and a first suggestion arrives.
for _ in $(seq 50); do grep -qE 'Google Chrome caret=.* -> "[^"]' "$LOG" && break; sleep 0.2; done
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi; }
# Type only into the fixture's textarea (its seed text), never the address bar.
for _ in $(seq 20); do "$DRIVE" value "$CH" 2>/dev/null | grep -q "^Thanks for sending" && break; sleep 0.3; done
"$DRIVE" value "$CH" 2>/dev/null | grep -q "^Thanks for sending" || { echo "ABORT: the textarea doesn't have focus"; exit 3; }
FAILED=0
shot() {
  read -r xy wh < <("$DRIVE" windows "$CH" | awk '/^cgwindow .* layer 0 on/ {print $6, $7; exit}')
  [ -n "${wh:-}" ] && screencapture -x -R"$xy,${wh/x/,}" "$OUT/$1.png"
}

front; "$DRIVE" type " Great news :tad" 110 || exit 3
sleep 1.2; shot 1-emoji; front; "$DRIVE" key tab; sleep 0.8
front; "$DRIVE" type " I will recieve " 110 || exit 3
sleep 1.2; shot 2-autocorrect; front; "$DRIVE" key tab; sleep 0.8
VALUE="$("$DRIVE" value "$CH")"
echo "$VALUE" >"$OUT/value.txt"
check "emoji replaced the shortcode" 'grep -q "Great news 🎉" <<<"$VALUE"'
check "Tab fixed recieve" 'grep -q "I will receive" <<<"$VALUE" && ! grep -q recieve <<<"$VALUE"'
if [ "${MARKERS:-0}" = 1 ]; then
  check "caret from text markers" 'grep -q "caret=textMarker" "$LOG"'
fi
grep -E "^\[ " "$LOG" | grep -v pending | tail -20
exit "$FAILED"
