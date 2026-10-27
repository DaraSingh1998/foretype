# Tools

## spike/ (Phase 0, archival)

The feasibility spike that preceded the app (2026-10-18/19). Kept for reproducibility; the
app does not depend on it.

- `probe/`: `axprobe`, a Swift CLI that logs the focused field's AX attributes, caret
  rects, fonts and per-call latency, with a listen-only key tap and optional Chromium
  priming. Logs lengths and geometry only, never text.
- `bench/`: llama-bench and warm-cache keystroke-loop scripts (`run_bench.sh`,
  `keystroke_loop.py`), the model list with pinned SHA-256 (`models.tsv`).
- `eval/`: the llama-server replay harness (`replay_eval.py`) and the corpus builder; the
  corpus itself is also at `../../eval/corpus.jsonl`. The raw oasst1 rows are not included
  (rebuild with `eval/corpus/build_corpus.py`).
- `results/`: summaries and per-run JSON/JSONL (large server logs omitted).
- `RESULTS.md`: the write-up. `README.md`: how to re-run.

Models are not included; see `../models/catalog.json`.

## confidence-sweep.py

Sweeps the confidence gate's bars (D51) over an `ft-replay --confidence-log FILE` (one JSON
line per keystroke showing a fresh model suggestion): per position kind (mid-word, after a
word) and bar, the suggestions kept, the right ones kept, precision and the wrong ones
removed, then how often the first word was right per probability band.
`python3 tools/confidence-sweep.py FILE`. An estimate: a held-back suggestion changes what
is typed next, so confirm a choice with a full replay (`--gate B,M`).
