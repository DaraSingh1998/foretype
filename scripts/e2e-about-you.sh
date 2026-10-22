#!/usr/bin/env bash
# End-to-end check of About You fills in a new, unsaved TextEdit document: the email after
# "My email is ", a phone number from its typed start, the name after "Regards,", nothing
# for a typed start that doesn't match, and no detail in the debug log. Prints PASS/FAIL.
#
# The details are fictional and come from FORETYPE_ABOUT_YOU, so the user's own stored
# details (about-you.bin, its Keychain key) are neither read nor written. Safety as in
# e2e-textedit.sh: FORETYPE_ONLY_APPS=com.apple.TextEdit, the test waits until the user has
# been idle for $IDLE seconds, every typing step aborts if focus leaves TextEdit, and the
# document is closed without saving.
#
# usage: FORETYPE_MODEL=/path/model.gguf scripts/e2e-about-you.sh [outdir]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/.build/release/Foretype"
DRIVE="$ROOT/build/ftdrive"
OUT="${1:-$ROOT/build/e2e-about-you}"
IDLE="${IDLE:-20}"
EMAIL="priya.raman@example.com"
mkdir -p "$OUT"
LOG="$OUT/foretype.log"
: "${FORETYPE_MODEL:?set FORETYPE_MODEL}"
[ -x "$DRIVE" ] || swiftc -O "$ROOT/scripts/ftdrive.swift" -o "$DRIVE"

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'; }
echo "waiting for ${IDLE}s of user inactivity..."
until [ "$(idle)" -ge "$IDLE" ]; do sleep 2; done

: >"$LOG"
FORETYPE_DEBUG=1 FORETYPE_ONLY_APPS=com.apple.TextEdit \
  FORETYPE_ABOUT_YOU="{\"name\":\"Priya Raman\",\"email\":\"$EMAIL\",\"phone\":\"+91 98765 43210\",\"in_prompt\":false}" \
  "$BIN" >>"$LOG" 2>&1 &
FT=$!
cleanup() {
  osascript -e 'tell application "TextEdit" to if (count of documents) > 0 then close document 1 saving no' >/dev/null 2>&1
  kill "$FT" 2>/dev/null
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

mark "1 email"
front; "$DRIVE" type " My email is " 110 || exit 3
sleep 1.0; shot 1-email
check "email offered" 'since "1 email" | grep -q " details .*<email, redacted>"'
front; "$DRIVE" key tab; sleep 0.8
check "one Tab inserted the whole email" 'doc | grep -q "My email is $EMAIL"'

mark "2 phone"
front; "$DRIVE" type " Call me on +91" 110 || exit 3
sleep 1.0; shot 2-phone
check "phone offered from its typed start" 'since "2 phone" | grep -q " details .*<phone, redacted>"'
front; "$DRIVE" key tab; sleep 0.8
check "Tab inserted the rest of the number" 'doc | grep -q "Call me on +91 98765 43210"'

mark "3 sign-off"
front; "$DRIVE" type $'\n\nRegards,\n' 110 || exit 3
sleep 1.0; shot 3-signoff
check "name offered after Regards," 'since "3 sign-off" | grep -q " details .*<name, redacted>"'
front; "$DRIVE" key tab; sleep 0.8
check "Tab took the first name" 'doc | tail -1 | grep -qx "Priya"'
front; "$DRIVE" key accept-all; sleep 0.8
check "accept-all took the rest" 'doc | tail -1 | grep -qx "Priya Raman"'

mark "4 no match"
front; "$DRIVE" type $'\nMy email is x' 110 || exit 3
sleep 1.0
# "My email is " is offered first; once "x" is typed the last event must be something else.
check "nothing filled for a different start" 'since "4 no match" | grep -E "^\[ " | grep -E " rev [0-9]+ " | tail -1 | grep -vq " details "'

check "no detail value in the debug log" '! grep -q "$EMAIL\|98765\|Priya Raman" "$LOG"'

doc >"$OUT/result.txt"
echo "--- document:"; cat "$OUT/result.txt"
echo "--- events:"; grep -E "^\[ |^===" "$LOG" | grep -v " pending" | tail -40
exit "$FAILED"
