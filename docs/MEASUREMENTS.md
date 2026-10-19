# Measurements

All numbers were measured on one machine unless noted: MacBook Pro (Mac15,6), Apple M3 Pro
(5P + 6E CPU, 14-core GPU), 18 GB RAM, macOS 27.0.1, on AC power, with Cotypist and Ollama
idle in the background. llama.cpp is the version vendored by `llama-cpp-2` 0.1.160 (Phase
1+) or Homebrew llama.cpp 0.7.0 (Phase 0 benchmarks). Models are from
`models/catalog.json`.

"Keystrokes saved" = 1 − keystrokes / characters, where accepting a word with Tab costs one
keystroke. The simulated user is ideal (accepts exactly when the next word matches, never
otherwise), so these are upper bounds for each policy. Base M1/M4 numbers and energy are
**not measured** yet.

## Phase 0 (2026-10-18/19): feasibility spike

Full write-up: `tools/spike/RESULTS.md`. Raw data: `tools/spike/results/`.

### Inference (llama-bench, Metal, all layers on GPU)

| Model | File | pp512 tok/s | tg128 tok/s |
|---|---:|---:|---:|
| Qwen3-0.6B-Base Q8_0 | 0.64 GB | 3,647 | 136.7 |
| Qwen3-1.7B-Base Q4_K_M | 1.11 GB | 1,264 | 89.2 |
| Qwen3-4B-Base Q4_K_M | 2.50 GB | 480 | 44.3 |

Warm-cache keystroke loop through llama-server (412-token context, one character per
keystroke at 150 ms, 8-token suggestions):

| Model | Prefill per keystroke | TTFT p50 / p90 | 8-token suggestion p50 / p90 |
|---|---:|---:|---:|
| 0.6B | 1 token | 12 / 17 ms | 68 / 72 ms |
| 1.7B | 1 token | 16 / 21 ms | 97 / 103 ms |
| 4B | 1 token | 25 / 33 ms | 186 / 209 ms |

Cold prefill of the 412-token field: 293 / 444 / 833 ms; model load 1–2 s.

### Accessibility (probe in `tools/spike/probe`)

- Keystroke → AX notification p50 5–9 ms, p90 9–12 ms in TextEdit, Safari (textarea) and
  Chrome; a full field snapshot costs 2–7 ms more. Safari's address bar reached p90 29 ms.
- Notes and Stickies match TextEdit (TextKit: caret rect one line high, zero-length marked
  range). Teams: no caret geometry at all. LibreOffice Writer: sentinel caret values and
  slow notifications (p50 32 ms). VS Code's editor exposes nothing without screen-reader
  mode. Edge works once primed.
- `AXAttributedStringForRange` (fonts) costs 3.3–3.8 ms in Safari: read once per field.

### Replay evaluation (llama-server harness, `tools/spike/eval`; 53 documents, 12,704 chars)

| Model | Keystrokes saved | Chars per accept | Suggestion p50 / p90 (4 words) |
|---|---:|---:|---:|
| Qwen3-0.6B Q8_0 | 39.3% | 3.65 | 58 / 95 ms |
| Qwen3-1.7B Q4_K_M | 41.7% | 3.76 | 81 / 123 ms |
| Qwen3-4B Q4_K_M | 44.2% | 3.87 | 150 / 226 ms |

Suggestion length (2/4/7 words) doesn't change savings under word-by-word accepting; it
changes cost (1.7B p50 53 / 81 / 119 ms; tokens per accepted character 2.05 / 2.78 / 4.13).

## Phase 1 (2026-10-19): in-process engine

`ft-replay`, Qwen3-1.7B, sample email (`scripts/fixtures/email.txt`, 400 chars primed):

| Run | Keystrokes saved | Chars per accept | Model p50 / p90 | Prefill per keystroke |
|---|---:|---:|---:|---:|
| 500 chars | 41.4% | 3.72 | 85 / 119 ms | 1 token (max 5) |
| 200 chars | 43.5% | 3.49 | 74 / 106 ms | 1 token |

58% of keystrokes were served by type-through with no inference. TextEdit end-to-end:
all six steps pass; first suggestion after focus 313 ms (cold prefill), later ones 50–120 ms.

## Phase 1+ (2026-10-19): screen context

`ft-replay` with `scripts/fixtures/chat-screen.txt` as screen text, typing
`chat-reply.txt` (a reply written to refer to the visible messages; best case):

| | Keystrokes saved | Chars per accept | Model p50 |
|---|---:|---:|---:|
| Without screen context | 28.8% | 3.24 | 57 ms |
| With screen context | 65.9% | 5.24 | 65 ms |

Vision OCR of a 720×420 window: 145–357 ms warm; the very first run on a Mac took 33.6 s
(model compilation).

## Phase 3 (2026-10-19): personalization and prefetch

Data: `docs/research/data-phase3-replay.txt`, `docs/research/data-phase3-ablation.txt`.
Qwen3-1.7B, full corpus (53 documents):

| | Keystrokes saved | Chars per accept | Model p50 / p90 |
|---|---:|---:|---:|
| Prefetch on, instant user | 41.9% | 3.68 | 75 / 105 ms |
| Prefetch off, instant user | 41.9% | 3.68 | 64 / 89 ms |

With an instant user, every prefetch is cancelled (one wasted decode step). With a 150 ms
reaction time (`--think 150`, the 3 `sw-email` documents): prefetch served 26 suggestions
instantly from cache (about 6% of model calls avoided) at p50 64 ms vs 67 ms without, with
no change in keystrokes saved.

Personalization, leave-one-out over the 12 self-written documents (each replayed with the
other 11 as history):

| Setting | Keystrokes saved |
|---|---:|
| Off | 41.0% |
| Gentle | 41.6% |
| Balanced (default) | 41.6% |
| Strong | 41.3% |
| Balanced, vocabulary bias only (no examples) | 41.2% |

The documents share few names and phrases, so this is a floor; real histories repeat more.

## Phase 4 (2026-10-19): server backends and packaging

`ft-replay`, sample email, 300 chars, against a local `llama-server` (same 1.7B model):

| Backend | Keystrokes saved | Model p50 / p90 |
|---|---:|---:|
| Built-in engine | 40.7% | 79 / 110 ms |
| llama-server (GBNF healing) | 40.7% (identical accepts) | 130–147 / 167–178 ms |
| OpenAI-compatible, partial word in prompt | 16.7% | 130 / 151 ms |
| OpenAI-compatible, filter only | 18.3% | cached / 117 ms |
| OpenAI-compatible, filter + fallback (shipped) | 20.3% | 160 / 280 ms |

CPU only (`--cpu`), Qwen3-0.6B, `sw-email-1`: 41.3% saved, p50 50 ms (M3 Pro CPU; CI
runners will be slower).

Model download self-test: 640 MB from a localhost server in 0.8 s including SHA-256
verification; a corrupted file was rejected and removed. DMG: 5.4 MB (llama.cpp linked
statically, Sparkle embedded).

## How to reproduce

See `docs/DEVELOPMENT.md` (ft-replay section). For release notes, run the full corpus with
the default model and record the summary line here.
