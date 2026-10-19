#!/usr/bin/env bash
# Runs replay_eval.py for each downloaded Qwen3 base model and writes results/eval/*.json.
#   ./run_eval.sh                      # all three models
#   BACKEND=http://127.0.0.1:8080 ./run_eval.sh   # evaluate an already-running engine instead
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT_DIR:-$HERE/../results/eval}"
mkdir -p "$OUT"
if [[ -n "${BACKEND:-}" ]]; then
  python3 -I "$HERE/replay_eval.py" --backend "$BACKEND" --out "$OUT/eval-backend.json"
  exit 0
fi
for m in Qwen3-0.6B-Base.Q8_0 Qwen3-1.7B-Base.Q4_K_M Qwen3-4B-Base.Q4_K_M; do
  echo "== $m"
  python3 -I "$HERE/replay_eval.py" --model "$HERE/../bench/models/$m.gguf" --server "$(command -v llama-server)" \
    --label "$m" --server-log "$OUT/server-$m.log" --out "$OUT/eval-$m.json" >/dev/null
done
python3 -I "$HERE/summarize_eval.py" "$OUT" | tee "$OUT/summary.md"
