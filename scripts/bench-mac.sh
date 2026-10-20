#!/usr/bin/env bash
# One-command benchmark for a Mac: the numbers docs/MEASUREMENTS.md still lacks for base M1
# and M4 machines. Replays the corpus with every installed catalog model and prints one
# summary line per model with the machine's chip, memory and OS, ready to paste.
#
#   scripts/bench-mac.sh [--only PREFIX]       (default: the full 53-document corpus)
#   FORETYPE_MODELS_DIR                        (default ~/Library/Application Support/Foretype/Models)
#   ENERGY=1                                   also measure GPU energy per suggestion (tools/energy;
#                                              CPU and DRAM need sudo powermetrics)
#
# Run on mains power with other GPU-heavy apps closed. Takes 5-20 minutes per model.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET=14.0
MODELS="${FORETYPE_MODELS_DIR:-$HOME/Library/Application Support/Foretype/Models}"
ONLY=()
[[ "${1:-}" == "--only" && -n "${2:-}" ]] && ONLY=(--only "$2")

cargo build --release --bins --manifest-path "$ROOT/core/Cargo.toml" >/dev/null 2>&1
R="$ROOT/core/target/release/ft-replay"
if [[ "${ENERGY:-0}" == 1 ]]; then
  mkdir -p "$ROOT/build"
  swiftc -O "$ROOT/tools/energy/energy.swift" -o "$ROOT/build/ft-energy"
fi

chip="$(sysctl -n machdep.cpu.brand_string)"
model="$(sysctl -n hw.model)"
ram="$(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
os="$(sw_vers -productVersion)"
power="$(pmset -g batt | head -1 | sed "s/.*'\(.*\)'.*/\1/")"
echo "machine: $chip ($model), $ram, macOS $os, $power"

files="$(python3 -c 'import json,sys; [print(m["file"]) for m in json.load(open(sys.argv[1]))["models"]]' "$ROOT/models/catalog.json")"
while IFS= read -r f; do
  [[ -f "$MODELS/$f" ]] || { echo "$f: not installed, skipped"; continue; }
  if [[ "${ENERGY:-0}" == 1 ]]; then
    out="$("$ROOT/build/ft-energy" --idle 15 -- "$R" "$MODELS/$f" --corpus "$ROOT/eval/corpus.jsonl" ${ONLY[@]+"${ONLY[@]}"} 2>&1)"
  else
    out="$("$R" "$MODELS/$f" --corpus "$ROOT/eval/corpus.jsonl" ${ONLY[@]+"${ONLY[@]}"} 2>&1)"
  fi
  line="$(grep 'docs in' <<<"$out" || true)"
  echo "$f: ${line:-failed}"
  if [[ "${ENERGY:-0}" == 1 ]]; then
    calls="$(sed -n 's/.*"model": \([0-9]*\).*/\1/p' <<<"$line")"
    net="$(sed -n 's/^net gpu: *\([-0-9.]*\) J.*/\1/p' <<<"$out")"
    grep -E '^(idle|energy|net gpu):' <<<"$out" | sed 's/^/    /'
    [[ -n "$calls" && -n "$net" ]] && python3 -c "import sys; n,c=float(sys.argv[1]),int(sys.argv[2]); print(f'    {1000*n/c:.1f} mJ of GPU energy per model suggestion ({c} suggestions)')" "$net" "$calls"
  fi
done <<<"$files"
