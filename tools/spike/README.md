# Phase 0 spikes

The Phase 0 spikes check the two riskiest assumptions in the blueprint (`reports/Cotypist internals and open source clone.md`). The first is whether Accessibility caret and latency reads are reliable across apps. The second is whether warm-cache inference is fast enough on real hardware. Measured numbers are in [RESULTS.md](RESULTS.md).

```
spike/
  probe/            SwiftPM CLI `axprobe` (no app bundle)
    Sources/axprobe/  main, Probe (observer+poll), Snapshot (AX reads, caret, font), WebAX (Chromium priming), KeyTap (listen-only tap, --type)
    fixtures/         testpage.html (textarea / #ce contenteditable), sample.txt (TextEdit)
    make_app.sh       builds bundle/AXProbe.app (bundle ID, full ad-hoc signature): the binary to grant
    make_bin.sh       older bare-binary variant (bin/axprobe)
    run_apps.sh       drives TextEdit, Safari, Chrome, Edge, or the focused field (current:NAME); JSONL out
    analyze.py        JSONL -> Markdown tables
  bench/
    run_bench.sh      llama-bench throughput + warm-depth prefill + keystroke loop
    keystroke_loop.py llama-server driver: per-keystroke TTFT with cache_prompt
    summarize.py      JSON -> Markdown tables
    models.tsv        model URLs + sha256 pins
  eval/
    replay_eval.py    keystroke replay with gate + token healing; --backend URL or --model GGUF
    run_eval.sh       three models (or BACKEND=url) -> results/eval
    summarize_eval.py JSON -> Markdown table
    corpus/           corpus.jsonl (self-written + OASST1 slice), build_corpus.py, README.md
  results/          raw outputs (probe/*.jsonl, bench/*.json, eval/*.json)
```

## axprobe

```bash
cd spike/probe && ./make_app.sh        # swift build + bundle/AXProbe.app
bundle/AXProbe.app/Contents/MacOS/axprobe --help
AXPROBE_LAUNCH="/Applications/Claude.app/Contents/Helpers/disclaimer --" ./run_apps.sh textedit safari chrome
EXPECT=com.apple.Notes ./run_apps.sh current:notes   # a document you opened yourself; types only into that app
python3 -I analyze.py
```

The tool prints one JSON object per line:

| `type` | When | Key fields |
|---|---|---|
| `env` | start | `axTrusted`, `listenEventAccess` (Input Monitoring), `postEventAccess`, `secureInput` |
| `observer` | frontmost app changes | AXObserver registration result per notification |
| `snapshot` | focus/selection/length change | `app.bundleId`, `role`/`subrole`, `valueLength`, `selectedTextRange`, `markedRange`, `caret` (zero-length rect, previous-char trailing edge, validation issues, chosen strategy), `axFont`, `calls[]` (every AX call with `ms` and error), `msSinceLastKeyDown`, `reason` (notification name or `poll`) |
| `key` | every key down/up/flags | `keyCode`, `synthetic`, `secureInput`, `tapLagMs` (characters only with `--log-chars`) |
| `secureInput` | state changes | `enabled`, holder app |
| `webPrime` / `webPrimeReadback` | `--chromium-ax` | flag values before/after, read-back after 100 ms, re-assert |
| `bench` | `--bench N` | p50/p90/max per AX call |
| `summary` | exit | notification counts, changes only the poll caught |

The probe never logs field text, only lengths. `--type` synthesises keystrokes; `--type-only-in BUNDLEID` stops them the moment any other app is frontmost, and `run_apps.sh` refuses to type without it. A snapshot with `reason: "poll"` is a change that no AX notification reported before the 200 ms poll found it.

**Permissions.** The process that macOS treats as "responsible" needs Accessibility. From Terminal, that is Terminal.app. Under Claude Code, the shell's responsible process is Claude Code's own binary, so `run_apps.sh` can be launched with `AXPROBE_LAUNCH="/Applications/Claude.app/Contents/Helpers/disclaimer --"`, which makes `axprobe` responsible for itself. Grant `bundle/AXProbe.app` (or `bin/axprobe`), never `.build/release/axprobe`: SwiftPM's linker-signed binary can never match a TCC record. The grant is tied to the cdhash, so after every `make_bin.sh` remove the old row with − and add the binary again. Toggling the switch is not enough.

## Benchmarks

```bash
cd spike/bench
./run_bench.sh --install --download   # asks nothing; flags are the consent
```

## Replay eval

```bash
cd spike/eval
./run_eval.sh                                   # Qwen3 0.6B / 1.7B / 4B via a fresh llama-server each
BACKEND=http://127.0.0.1:8080 ./run_eval.sh     # any engine exposing llama-server's /completion
python3 -I replay_eval.py --model ../bench/models/Qwen3-1.7B-Base.Q4_K_M.gguf --max-docs 2   # smoke test
```

Backend contract: `POST /completion` with `prompt`, `n_predict`, `grammar` (GBNF), `temperature: 0`, `cache_prompt`, `stream: true`; server-sent `data:` events with `content` per token and a final `stop` event.
