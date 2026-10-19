#!/usr/bin/env bash
# Phase 0 inference spike: llama-bench throughput, warm-cache few-token prefill, and a
# simulated keystroke loop for Qwen3 0.6B / 1.7B / 4B base GGUFs.
#
#   ./run_bench.sh                     # run with whatever is installed/downloaded
#   ./run_bench.sh --install           # brew install llama.cpp if llama-bench is missing
#   ./run_bench.sh --download          # fetch missing models (sha256-verified)
#   ./run_bench.sh --models "0.6b 1.7b" --skip-loop
#
# Nothing is installed or downloaded unless the matching flag is given.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODELS_DIR="${MODELS_DIR:-$HERE/models}"
OUT_DIR="${OUT_DIR:-$HERE/../results/bench}"
INSTALL=0 DOWNLOAD=0 SKIP_LOOP=0 MODELS="0.6b 1.7b 4b" REPS=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --download) DOWNLOAD=1 ;;
    --skip-loop) SKIP_LOOP=1 ;;
    --models) MODELS="$2"; shift ;;
    --reps) REPS="$2"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

say() { printf '\n== %s\n' "$*"; }

# --- llama.cpp ---------------------------------------------------------------
if ! command -v llama-bench >/dev/null; then
  if [[ $INSTALL == 1 ]]; then
    say "Installing llama.cpp via Homebrew"
    brew install llama.cpp
  else
    echo "llama-bench not found. Re-run with --install, or: brew install llama.cpp" >&2
    exit 3
  fi
fi
BENCH="$(command -v llama-bench)"
SERVER="$(command -v llama-server)"

# --- models ------------------------------------------------------------------
mkdir -p "$MODELS_DIR" "$OUT_DIR"
PATHS=()
for key in $MODELS; do
  line="$(awk -F'\t' -v k="$key" '$1==k' "$HERE/models.tsv")"
  [[ -n "$line" ]] || { echo "unknown model key $key" >&2; exit 64; }
  IFS=$'\t' read -r _ file url sha bytes <<<"$line"
  path="$MODELS_DIR/$file"
  if [[ ! -f "$path" ]]; then
    if [[ $DOWNLOAD == 1 ]]; then
      say "Downloading $file ($((bytes / 1000000)) MB)"
      curl -L --fail --retry 3 -C - -o "$path.part" "$url"
      got="$(shasum -a 256 "$path.part" | cut -d' ' -f1)"
      if [[ "$got" != "$sha" ]]; then
        echo "sha256 mismatch for $file: got $got want $sha (left as $path.part)" >&2
        exit 4
      fi
      mv "$path.part" "$path"
    else
      echo "skipping $key: $path missing (re-run with --download)" >&2
      continue
    fi
  fi
  PATHS+=("$path")
done
[[ ${#PATHS[@]} -gt 0 ]] || { echo "no models available" >&2; exit 5; }

# --- environment -------------------------------------------------------------
say "Environment"
{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "model: $(sysctl -n hw.model) / $(sysctl -n machdep.cpu.brand_string)"
  echo "cpu: $(sysctl -n hw.perflevel0.physicalcpu)P + $(sysctl -n hw.perflevel1.physicalcpu)E cores"
  echo "gpu: $(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Total Number of Cores/{print $2; exit}') cores"
  echo "ram: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
  echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "power: $(pmset -g batt | head -1 | sed "s/.*'\(.*\)'.*/\1/")"
  echo "llama.cpp: $("$BENCH" --version 2>&1 | grep -iE '^version|built with' | tr '\n' ' ')"
} | tee "$OUT_DIR/environment.txt"

MARGS=()
for p in "${PATHS[@]}"; do MARGS+=(-m "$p"); done

# --- 1. throughput -----------------------------------------------------------
say "llama-bench throughput (pp512, tg128, ${REPS} reps)"
"$BENCH" "${MARGS[@]}" -ngl 99 -p 512 -n 128 -r "$REPS" -o json >"$OUT_DIR/llama-bench-throughput.json"

# --- 2. warm-cache few-token prefill -----------------------------------------
say "llama-bench few-token prefill at depth (pp1/4/8 and tg8 at d512, d2048)"
"$BENCH" "${MARGS[@]}" -ngl 99 -p 1,4,8 -n 8 -d 512,2048 -r "$REPS" -o json >"$OUT_DIR/llama-bench-warm.json"

# --- 3. simulated keystroke loop ---------------------------------------------
if [[ $SKIP_LOOP == 0 ]]; then
  for p in "${PATHS[@]}"; do
    name="$(basename "$p" .gguf)"
    say "Keystroke loop: $name"
    python3 -I "$HERE/keystroke_loop.py" --server "$SERVER" --model "$p" \
      --server-log "$OUT_DIR/server-$name.log" --out "$OUT_DIR/loop-$name.json"
  done
fi

say "Summary"
python3 -I "$HERE/summarize.py" "$OUT_DIR" | tee "$OUT_DIR/summary.md"
