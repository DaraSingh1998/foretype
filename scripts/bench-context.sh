#!/usr/bin/env bash
# Cross-app context baseline (docs/MEASUREMENTS.md, "Cross-app context baseline"): for every
# installed catalog model, keystrokes saved on eval/corpus-multiwindow.jsonl with no screen
# context, the focused window's text, the other app's text and both; then the long-context
# cost (first suggestion, prefill, keystrokes, memory) at each context size.
#
#   scripts/bench-context.sh [N_CTX...]        (default: 2048 4096 8192)
#   FORETYPE_MODELS_DIR                        (default ~/Library/Application Support/Foretype/Models)
#   MODES="none both"                          (default: none focused other both; other and both
#                                              go through the other-apps section since Phase C,
#                                              other-screen and both-screen are Phase A's stand-in)
#   SWITCH="16 8"                              (default: both) typing across a change of the
#                                              other-apps section (`--switch-bench`, D47) as a 16 GB
#                                              Mac runs it (n_ctx 4096, two slots, 2,048-token
#                                              section) and as one under 16 GB does (4,096 cells
#                                              shared by both slots, 512-token section); "" skips it
#   ENGINE="--kv f16 --slots 1"                (extra ft-replay flags for every run, e.g. the engine
#                                              before Phase D)
#
# Waits while another ft-replay runs, and marks a result "(shared GPU)" if one started
# during it. Run on mains power with other GPU-heavy apps closed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET=14.0
MODELS="${FORETYPE_MODELS_DIR:-$HOME/Library/Application Support/Foretype/Models}"
CORPUS="$ROOT/eval/corpus-multiwindow.jsonl"
SIZES=("$@")
[[ ${#SIZES[@]} -gt 0 ]] || SIZES=(2048 4096 8192)
read -r -a MODE_LIST <<<"${MODES:-none focused other both}"
read -r -a SWITCH_LIST <<<"${SWITCH-16 8}"
read -r -a ENGINE_FLAGS <<<"${ENGINE:-}"

cargo build --release --bins --manifest-path "$ROOT/core/Cargo.toml" >/dev/null
R="$ROOT/core/target/release/ft-replay"

chip="$(sysctl -n machdep.cpu.brand_string)"; ram="$(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
power="$(pmset -g batt | head -1 | sed "s/.*'\(.*\)'.*/\1/")"
echo "machine: $chip ($(sysctl -n hw.model)), $ram, macOS $(sw_vers -productVersion), $power, $(git -C "$ROOT" rev-parse --short HEAD)"

# Runs ft-replay alone on the GPU: waits for others to finish, notes any that start meanwhile.
alone() {
  while pgrep -x ft-replay >/dev/null; do sleep 2; done
  local log; log="$(mktemp)"
  ( while sleep 2; do [[ "$(pgrep -x ft-replay | wc -l)" -gt 1 ]] && echo shared >"$log"; done ) &
  local watcher=$!
  local out; out="$("$R" "$@" ${ENGINE_FLAGS[@]+"${ENGINE_FLAGS[@]}"} 2>&1)" || true
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null || true
  [[ -s "$log" ]] && out="$out (shared GPU)"
  rm -f "$log"
  printf '%s\n' "$out"
}

files="$(python3 -c 'import json,sys; [print(m["file"]) for m in json.load(open(sys.argv[1]))["models"]]' "$ROOT/models/catalog.json")"
while IFS= read -r f; do
  [[ -f "$MODELS/$f" ]] || { echo "$f: not installed, skipped"; continue; }
  for m in "${MODE_LIST[@]}"; do
    line="$(alone "$MODELS/$f" --corpus "$CORPUS" --context-mode "$m" | grep -E 'docs in|shared GPU' || true)"
    echo "$f context $m: ${line:-failed}"
  done
  for n in "${SIZES[@]}"; do
    alone "$MODELS/$f" --corpus "$CORPUS" --ctx-bench --n-ctx "$n" | grep -E '^(ctx-bench|memory)|shared GPU' | sed "s|^|$f |"
  done
  for mac in ${SWITCH_LIST[@]+"${SWITCH_LIST[@]}"}; do
    case "$mac" in
      16) args=(--n-ctx 4096 --other-tokens 2048) ;;
      8) args=(--n-ctx 4096 --kv-cells 4096 --other-tokens 512) ;;
      *) echo "SWITCH=$mac: expected 16 or 8"; continue ;;
    esac
    alone "$MODELS/$f" --corpus "$CORPUS" --switch-bench "${args[@]}" | grep -E '^switch-bench|shared GPU' | sed "s|^|$f ($mac GB) |"
  done
done <<<"$files"
