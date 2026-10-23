#!/usr/bin/env bash
# Inline ghost text while typing, in a chat composer whose app gives no Accessibility caret:
# a test Chrome (throwaway profile) opens scripts/fixtures/composer.html, which types into
# its own fields by itself (wrap, new line, numbered list, a new field). Foretype logs how
# each suggestion was drawn (`show=inline|card|mirror|hidden`); the report counts them per
# segment and counts card-to-inline jumps. Right after a suggestion is drawn (up to 4 times
# per segment) the window region is saved to OUT as SEGMENT-N-MODE.png.
#
# Safety: no keystrokes are sent to the system (the page types into itself and pauses while
# its window is not focused). Foretype runs with FORETYPE_ONLY_APPS set to the test Chrome's
# pid, so your own Chrome is never read. The test Chrome is quit at the end and focus goes
# back to the app that was in front. Stops if you use the keyboard or mouse.
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-inline-caret.sh [ce|textarea] [outdir]
#        FORETYPE_CARET=pixel (the default here) forces the pixel caret locator, as in apps
#        that report no caret; FORETYPE_CARET= (empty) leaves Chrome's own AX caret on.
#        WINDOW_POS=X,Y opens the test window there (global points, top-left origin), e.g. on a
#        display above the main one (negative y).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/mac/.build/release/Foretype}"
DRIVE="$ROOT/build/ftdrive"
MODE="${1:-ce}"
OUT="${2:-$ROOT/build/e2e-inline-caret/$MODE}"
IDLE="${IDLE:-10}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PAGE="file://$ROOT/scripts/fixtures/composer.html#$MODE"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
export FORETYPE_CARET="${FORETYPE_CARET-pixel}"
# Empty About You details: a development binary reading the saved ones would make the
# Keychain ask for the login password (the key's access list names the installed app only).
[ -n "${FORETYPE_ABOUT_YOU+set}" ] || export FORETYPE_ABOUT_YOU='{}'
mkdir -p "$OUT" "$ROOT/build"
rm -f "$OUT"/*.png
LOG="$OUT/foretype.log"
[[ -x "$DRIVE" ]] || swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE" || exit 1

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
echo "waiting for ${IDLE}s of user inactivity..."
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done

BEFORE="$("$DRIVE" front-pid)"
PROFILE="$(mktemp -d -t foretype-chrome)"
"$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
  ${WINDOW_POS:+--window-position="$WINDOW_POS" --window-size=1000,600} --new-window "$PAGE" >/dev/null 2>&1 &
CH=$!
# Appending (O_APPEND), so the segment marks this script adds are not overwritten.
: >"$LOG"
FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS="$CH" "$BIN" >>"$LOG" 2>&1 &
FT=$!
cleanup() {
  kill "$FT" 2>/dev/null; wait "$FT" 2>/dev/null
  kill "$CH" 2>/dev/null; "$DRIVE" raise "$BEFORE" 2>/dev/null; wait "$CH" 2>/dev/null
  rm -rf "$PROFILE"
}
trap cleanup EXIT
for _ in $(seq 60); do grep -q "engine ready" "$LOG" && break; sleep 0.5; done
grep -q "engine ready" "$LOG" || { echo "engine did not start"; exit 1; }

for _ in $(seq 20); do "$DRIVE" raise "$CH" && [ "$("$DRIVE" front-pid)" = "$CH" ] && break; sleep 0.5; done
[ "$("$DRIVE" front-pid)" = "$CH" ] || { echo "could not raise the test Chrome"; exit 1; }
START=$(date +%s)
user_back() { [ "$(idle)" -lt $(( $(date +%s) - START )) ]; }

last=""
shown=0
shots=0
status=0
for _ in $(seq 900); do
  if user_back; then echo "ABORT: the user is active again"; status=3; break; fi
  [ "$("$DRIVE" front-pid)" = "$CH" ] || { echo "ABORT: the test Chrome left the front"; status=3; break; }
  title="$("$DRIVE" title "$CH" 2>/dev/null)"
  case "$title" in *"composer fixture: "*) seg="${title#*composer fixture: }"; seg="${seg%% - *}" ;; *) seg="" ;; esac
  if [ -n "$seg" ] && [ "$seg" != "$last" ]; then
    echo "=== $seg" >>"$LOG"
    echo "=== $seg"
    last="$seg"
    shots=0
  fi
  [ "$seg" = finished ] && break
  # A screenshot right after a suggestion is drawn (the overlay is its own window, so a
  # region of the screen, not the window).
  now="$(grep -cE ' show=(inline|card|mirror)' "$LOG")"
  if [ "$now" -gt "$shown" ] && [ $shots -lt 4 ] && [ -n "$seg" ] && [[ "$seg" != *done ]] && [ "$seg" != waiting ]; then
    mode="$(grep -oE ' show=(inline|card|mirror)' "$LOG" | tail -1)"
    shots=$((shots + 1))
    r="$("$DRIVE" frame "$CH" 2>/dev/null)" && screencapture -x -R"$r" "$OUT/${seg}-${shots}-${mode# show=}.png" 2>/dev/null
  fi
  shown="$now"
  sleep 0.1
done
if [ "$last" != finished ] && [ $status = 0 ]; then echo "the fixture did not finish"; status=1; fi

echo "--- how suggestions were drawn, per segment (FORETYPE_CARET=${FORETYPE_CARET:-unset}):"
awk '
  /^=== / { seg = substr($0, 5); next }
  / show=/ && seg != "" && seg !~ /done$/ && seg != "waiting" {
    match($0, / show=[a-z]+/); m = substr($0, RSTART + 6, RLENGTH - 6)
    if (m == "hidden") next
    count[seg, m]++; segs[seg] = 1
    if (prev[seg] != "" && prev[seg] != "inline" && m == "inline") jumps[seg]++
    prev[seg] = m
  }
  END {
    for (s in segs) printf "%-16s %7d %6d %7d %13d\n", s, count[s, "inline"], count[s, "card"], count[s, "mirror"], jumps[s]
  }' "$LOG" | sort | { printf "%-16s %7s %6s %7s %13s\n" segment inline card mirror "card->inline"; cat; }
echo "--- caret strategies of shown suggestions:"
grep -E ' show=(inline|card|mirror)' "$LOG" | grep -oE 'caret=[a-z+()A-Z]+' | sort | uniq -c
echo "log: $LOG; screenshots in $OUT"
exit $status
