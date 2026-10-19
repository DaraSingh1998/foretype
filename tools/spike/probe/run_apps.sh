#!/usr/bin/env bash
# Drives TextEdit, Safari and Chrome through the probe and saves JSONL per scenario.
# Each scenario: open a fixture, snapshot once, watch while the probe types a short
# phrase into the field, then time 30 back-to-back snapshots.
#
#   ./run_apps.sh [scenario ...]     scenarios: textedit safari safari-ce chrome chrome-ax chrome-ce-ax edge edge-ax
#   EXPECT=BUNDLEID ./run_apps.sh current:NAME
#                                    probe whatever field is focused now (no fixture); typing needs
#                                    EXPECT and stops if any other app is frontmost; TYPE=0 skips
#                                    synthetic typing (read-only), SETTLE=seconds before the first read, PROBE_FLAGS=extra flags (e.g. --chromium-ax)
#
# Don't touch the keyboard or mouse while it runs: typing aborts if focus leaves the app.
# AXPROBE_LAUNCH lets you prefix the binary (e.g. a launcher that makes axprobe its own
# TCC-responsible process); empty when run from a terminal that has Accessibility.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${AXPROBE_BIN:-$HERE/bundle/AXProbe.app/Contents/MacOS/axprobe}"
OUT="${OUT_DIR:-$HERE/../results/probe}"
read -r -a LAUNCH <<<"${AXPROBE_LAUNCH:-}"
PHRASE="${PHRASE:- we should keep going. Next week}"
mkdir -p "$OUT"
[[ -x "$BIN" ]] || { echo "missing $BIN: run make_app.sh" >&2; exit 1; }

WORK="$(mktemp -d)"
cp "$HERE/fixtures/sample.txt" "$WORK/sample.txt" # TextEdit autosaves; never touch the fixture
PAGE="file://$HERE/fixtures/testpage.html"

probe() { ${LAUNCH[@]+"${LAUNCH[@]}"} "$BIN" "$@"; }

run() {
  local name="$1"; shift
  local flags=("$@")
  echo "== $name"
  sleep "${SETTLE:-2.5}"
  probe --once ${flags[@]+"${flags[@]}"} >"$OUT/$name.once.jsonl" || true
  if [[ "${TYPE:-1}" == 1 ]]; then
    if [[ -z "${EXPECT:-}" ]]; then
      echo "   no EXPECT bundle id for $name: skipping typing" >&2
    else
      probe --duration 9 --poll-ms 200 --type "$PHRASE" --type-start-ms 1500 --type-interval-ms 120 \
        --type-only-in "$EXPECT" --goto-end ${flags[@]+"${flags[@]}"} >"$OUT/$name.watch.jsonl" || true
    fi
  fi
  probe --bench 30 ${flags[@]+"${flags[@]}"} >"$OUT/$name.bench.jsonl" || true
}

scenarios=("$@")
[[ ${#scenarios[@]} -gt 0 ]] || scenarios=(textedit safari safari-ce chrome chrome-ax chrome-ce-ax)

for s in "${scenarios[@]}"; do
  case "$s" in
    textedit) open -a TextEdit "$WORK/sample.txt"; EXPECT=com.apple.TextEdit run textedit ;;
    safari) open -a Safari "$PAGE"; EXPECT=com.apple.Safari run safari ;;
    safari-ce) open -a Safari "$PAGE#ce"; EXPECT=com.apple.Safari run safari-ce ;;
    chrome) open -a "Google Chrome" "$PAGE"; EXPECT=com.google.Chrome run chrome ;;
    chrome-ax) open -a "Google Chrome" "$PAGE"; EXPECT=com.google.Chrome run chrome-ax --chromium-ax ;;
    chrome-ce-ax) open -a "Google Chrome" "$PAGE#ce"; EXPECT=com.google.Chrome run chrome-ce-ax --chromium-ax ;;
    edge) open -a "Microsoft Edge" "$PAGE"; EXPECT=com.microsoft.edgemac run edge ;;
    edge-ax) open -a "Microsoft Edge" "$PAGE"; EXPECT=com.microsoft.edgemac run edge-ax --chromium-ax ;;
    current:*) run "${s#current:}" ${PROBE_FLAGS:-} ;;
    *) echo "unknown scenario $s" >&2 ;;
  esac
done
echo "done: $OUT (TextEdit copy in $WORK)"
