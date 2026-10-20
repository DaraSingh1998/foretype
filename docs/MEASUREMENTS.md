# Measurements

All numbers were measured on one machine unless noted: MacBook Pro (Mac15,6), Apple M3 Pro
(5P + 6E CPU, 14-core GPU), 18 GB RAM, macOS 27.0.1, on AC power, with Cotypist and Ollama
idle in the background. llama.cpp is the version vendored by `llama-cpp-2` 0.1.160 (Phase
1+) or Homebrew llama.cpp 0.7.0 (Phase 0 benchmarks). Models are from
`models/catalog.json`.

"Keystrokes saved" = 1 − keystrokes / characters, where accepting a word with Tab costs one
keystroke. The simulated user is ideal (accepts exactly when the next word matches, never
otherwise), so these are upper bounds for each policy. Base M1/M4 numbers are **not
measured** yet (`scripts/bench-mac.sh` produces them on any Mac); energy is GPU-only
without root (see the leftovers section).

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

## Leftovers (2026-10-19/20): KV snapshots, energy, Chrome, by-eye checks

### Cache rollback (`ft-replay --check-cache`)

Each document is typed one character at a time with a burst of 3 backspaces every 9
keystrokes, through an engine that reuses its cache and through one reset before every
request; the table counts identical suggestions (4 words, greedy). Short: the first 200
characters of 4 documents (prompts under 100 tokens). Long (`--long`): 1,400 characters of
other documents as screen text and as earlier body text, so prompts run 650–700 tokens,
past Gemma 4's 512-token window.

| Model | Rollback | Prompts | Identical | Prefill per request p50 / p90 | Reuse p50 | Fresh p50 |
|---|---|---|---:|---:|---:|---:|
| Qwen3-0.6B Q8_0 | truncate | short | 99.9% (1,418 / 1,420) | 1 / 1 | 39 ms | 49 ms |
| Qwen3-1.7B Q4_K_M | truncate | long | 99.7% (796 / 798) | 1 / 1 | 56 ms | 581 ms |
| Qwen3.5-0.8B Q8_0 | snapshot | short | 100% (1,420 / 1,420) | 1 / 2 | 47 ms | 74 ms |
| Qwen3.5-0.8B Q8_0 | snapshot | long | 100% (798 / 798) | 1 / 2 | 49 ms | 298 ms |
| Gemma 4 E2B Q4_K_M | truncate (full SWA) | short | 96.9% (1,376 / 1,420) | 1 / 1 | 77 ms | 138 ms |
| Gemma 4 E2B Q4_K_M | truncate (full SWA) | long | 88.6% (707 / 798) | 1 / 1 | 79 ms | 846 ms |

Gemma 4's lower rate is rounding, not rollback: on 2 long documents (424 requests), two
fresh contexts that differ only in prefill batch size (16 vs 512 tokens) agreed on 91.7%,
while the reusing engine agreed with the 16-token fresh pass on 98.1% (91.0% with the
512-token one). The reusing engine prefills in small steps as the user types, so it lands
closer to small-batch numerics. Gemma 4 is more sensitive to this than Qwen (near-ties in
greedy decoding); the suggestions on both sides read as plausible continuations.

### Chrome before priming (`tools/spike/probe/run_unprimed_chrome.sh`)

Chrome 155.0.8059.85, a separate process with a throwaway profile, raised to the front with
the fixture textarea focused (its focus ring visible on screen), probed by pid:

- `AXEnhancedUserInterface` was `false`: this process had not been primed by anyone, so this
  is the baseline Phase 0 could not get.
- The app element answered (native toolbar buttons, window title), but
  `AXFocusedUIElement` returned `noValue`: no web element, so no text, caret or font.
- Setting `AXEnhancedUserInterface` succeeded (read back `true` after 100 ms;
  `AXManualAccessibility` is unsupported, as before), yet the focused element stayed
  `noValue` in reads at 0.4, 1, 2, 4 and 8 s. Resetting the flag returns `notImplemented`.
- Walking the window's AX tree first (as an observer-based client does) didn't change it.

That conclusion was wrong: `axprobe --once --chromium-ax` reads 0.5 s after setting the
flag and clears it when it exits, and Chrome drops the request when the flag is cleared
within 2 s (next section).

### Fresh Chrome: what turns web content on (`tools/spike/probe/run_chrome_triggers.sh`)

Same Chrome and fixture, a new throwaway-profile process per trigger, raised, then the
app's `AXFocusedUIElement` read every 250 ms for 10 s by `build/chrome_triggers` (a bare
binary, so no AXProbe re-grant). `AXEnhancedUserInterface` read `false` before every run;
Raycast was running, nothing else that primes Chromium. Raw lines:
`tools/spike/results/probe/chrome-triggers.jsonl`.

| Trigger | Focused web textarea | Web area in the window's tree at 10 s |
|---|---|---|
| None (only the reads) | never (`noValue`) | no |
| AXObserver on the app, as FocusTracker attaches it | never; no notifications | no |
| `AXFocusedUIElement` of the focused window | never (`attributeUnsupported`) | no |
| Walk the window's tree first (36 nodes, native UI only) | never | no |
| Hit test at the window's middle (returns the web view, `AXScrollArea`) | never | no |
| Page moves focus between two textareas every 1.5 s, with or without an observer | never | no |
| `AXManualAccessibility` | never (`attributeUnsupported`) | no |
| `AXEnhancedUserInterface` set, cleared after 0.5 s | never | no |
| `AXEnhancedUserInterface` set and kept, with or without an observer | at 2.06 s (3 runs: 2.061, 2.066, 2.056) | yes |
| Chrome started with `--force-renderer-accessibility` | at the first read (0.27 s) | yes |

With the flag kept, text, caret and caret rect match the renderer-flag run
(`AXBoundsForRange` of the character before the caret: 281,248 10×19). Setting the flag
returns `notImplemented` even though it works.

Why: Chrome's application object (`chrome/browser/chrome_browser_application_mac.mm`)
debounces `AXEnhancedUserInterface`. A set starts a 2 s timer, a clear inside those 2 s
cancels it, and only when the timer fires does Chrome turn on complete accessibility, web
content included. An outside client asking the app for its role turns on only the native
UI (`kNativeAPIs`, the "Sonoma refinements"), which is why the toolbar answers. Chromium's
web view also turns on basic web support when an assistive app asks its role, but in Chrome
155 a hit test that reached it didn't build the tree. The user's long-running Chrome is
readable because some client kept the flag set for 2 s at some point.

### Fresh Chrome in Foretype (`scripts/e2e-chrome-fresh.sh`)

Development build, Qwen3-0.6B Q8_0, `FORETYPE_ONLY_APPS` set to the test Chrome's pid,
nothing typed; seconds from Foretype first setting the flag (Chrome activated itself at
launch) to the ghost text, model time included (75–150 ms). Then the flag is cleared from
outside (`chrome_triggers PID clear`). Logs: `tools/spike/results/probe/e2e-chrome-fresh/`.

| Run | First set kept? | Ghost text | After the outside clear |
|---|---|---|---|
| 1 | yes | 2.12 s | flag set again within 1 s, text 2.1 s later |
| 2 | no: read `false` at 0.6 s, set again | 3.15 s | set again, text 2.6 s later |
| 3 | no: read `false` at 0.5 s, set again | 3.10 s | set again, text 2.6 s later |

Something clears the flag within 0.5 s of Chrome's launch or activation in about half the
runs (Tabber saw Chrome clear it within ~50 ms of activation); a clear inside the 2 s
window cancels Chrome's pending switch, so FocusTracker checks the flag 0.5 s after each set.
Before that check, 2 of 3 runs showed text only at 6.6 s (set again by the 3 s no-focus
check). An earlier version that set the flag again whenever a read of it timed out kept
restarting Chrome's 2 s wait (the field became readable only at 4.5 s). The overlay sits on the caret's baseline in
the field's serif font (`build/e2e-chrome-1/1-fresh.png`, by eye).

### By-eye checks (2026-10-20)

Development build with `FORETYPE_ONLY_APPS=com.apple.TextEdit` (e2e script) and the
bundled Sparkle test build, screenshots through `screencapture` and `ftdrive`:

- Ghost text in TextEdit sits on the caret's baseline in the field's font, gray, after a
  space and mid-word (`build/e2e/1-suggestion.png`, `4-midword.png` when re-run).
- Live screen capture: "screen: 92 chars from TextEdit in 295 ms" (Vision OCR of the window).
- Setup window: the Accessibility, Screen Recording and model rows show their state; buttons
  for granted or installed items are disabled; Start stays disabled until Accessibility is
  granted.
- Menu: all items render; the per-app toggle follows the frontmost app.
- Custom Instructions: global and per-app fields, Cancel / Save (about 50 pt of empty space
  under the buttons).
- Sparkle: 0.0.1 → 0.0.2 from a local feed, "OK: EdDSA signature is correct for update",
  installed in place and relaunched; the next check said "You're up to date!".

### Models and energy

Full corpus (53 documents, 12,704 characters), built-in engine, Metal, 4 words, prefetch
on (mains power), instant simulated user, run one after another on 2026-10-20. Energy is
the GPU counter from `tools/energy` (GPU energy during the run minus idle GPU power, divided
by model suggestions; prefetch decodes are included, cache and type-through hits cost
nothing). CPU and DRAM are not included: their counters don't update reliably without root.

| Model | File | Keystrokes saved | Chars per accept | Model p50 / p90 | Model calls | GPU energy per suggestion | Mean GPU power |
|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen3-0.6B Q8_0 | 0.64 GB | 39.9% | 3.61 | 46 / 61 ms | 3,341 | 0.61 J | 12.3 W |
| Qwen3.5-0.8B Q8_0 | 0.81 GB | 39.1% | 3.54 | 74 / 93 ms | 3,377 | 0.93 J | 12.1 W |
| Qwen3-1.7B Q4_K_M | 1.11 GB | 41.9% | 3.68 | 73 / 101 ms | 3,063 | 1.13 J | 14.3 W |
| Gemma 4 E2B Q4_K_M | 3.43 GB | 42.8% | 3.78 | 109 / 159 ms | 3,156 | 1.52 J | 13.0 W |
| Qwen3-4B Q4_K_M | 2.50 GB | 45.0% | 3.84 | 147 / 203 ms | 2,889 | 2.47 J | 15.6 W |

- Qwen3-1.7B reproduces Phase 3 exactly (41.9%), so the rollback rework changed nothing for
  dense models.
- Qwen3.5-0.8B is worse than Qwen3-0.6B on every column, so it is not in the catalog.
  Gemma 4 E2B sits between the 1.7B and 4B models on savings and latency, with the largest
  file; it is in the catalog as an opt-in "quality" model, never picked automatically.
- Mean GPU power is high because an instant simulated user keeps the GPU busy the whole
  time; for a person typing, energy per suggestion is the useful figure (about 1 J for the
  default model, so 1,000 suggestions ≈ 0.3 Wh of GPU energy).
- Gemma 4 loads in 2.4 s (Qwen3-1.7B: 0.5 s).
- The `idle` baselines were 0.00–0.37 W; earlier on 2026-10-20 the same meter read ~20 W
  of GPU "idle" while another replay was still running, so measure with nothing else
  on the GPU.

## Backlog features (2026-10-20)

Qwen3-1.7B Q4_K_M, full corpus, 4 words, prefetch on, instant simulated user, unless noted.

### Phrase beam search (`ft-replay --beam N`)

| Beams | Keystrokes saved | Chars per accept | Model p50 / p90 | GPU energy (whole corpus) |
|---:|---:|---:|---:|---:|
| 1 (greedy) | 41.9% | 3.68 | 70–77 / 97–106 ms | 3,380 J |
| 3 | 43.0% | 3.69 | 86–94 / 103–126 ms | 3,883 J (+15%) |
| 4 | 42.7% | 3.66 | 92 / 110 ms | |
| 6 | 42.4% | 3.64 | 98 / 118 ms | |
| 9 | 42.3% | 3.64 | 103 / 125 ms | |

Wider beams find more probable *phrases*, which is not the same as getting the next word
right; 3 is the best width here. The app uses 3 beams on mains power and greedy on battery
(set by the shell, like prefetch). On the 3 email documents alone, 4 beams gave 44.4% vs
42.9%. Each beam is a KV sequence of a unified cache; making every context multi-sequence
changed nothing for greedy (`--check-cache`, Qwen3-0.6B: 99.9% identical, same latency).

### Mid-line (`ft-replay --mid-line-eval`)

At word starts in the middle of lines (every 5th, with 3+ words before and 2+ after on the
line), the word replaced by its first letters, the rest of the line as the suffix:

| Prompt | 1 letter typed (340 positions) | 2 letters (262) |
|---|---:|---:|
| Fill-in-the-middle (`<|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>`) | 5.6% right | 9.9% |
| Plain continuation, cut where it repeats the line (shipped) | 72.1% right, p50 48 ms | 77.9%, p50 54 ms |

Qwen3 base has FIM tokens but produced code-like noise with them on prose
("tantiateViewController", "oMatchSnapshot"). Mid-line stays an experimental setting, off by
default.

### Typo gate and autocorrect (`ft-replay --spell`)

The corpus has no typos, so every block or correction on it is a false one. The macOS spell
checker (via `tools/spell-map`, the app's own `Speller`, language en_IN) flagged 19 of
2,792 distinct fragments as impossible; all but the lowercase `malbolge…` and the American
`apologiz…` are capitalized and pass as likely names. Replaying with the verdicts: 4
requests blocked, keystrokes saved unchanged at 41.9%. Autocorrect proposed nothing (its
one candidate, "ROblox" → "Roblox", is capitalized mid-sentence and treated as a name).
Spell-checker calls cost 0.1–1 ms each off the main thread once warm (about 11 ms for the
first).

### Apple on-device model (`shell` backend)

`AppleModel.complete` with the core's request format, on this M3 Pro (macOS 27.0.1):
2.2 s for the first request, then 0.45–0.6 s; continuations were sensible ("closer to
agreement than the" → "previous discussion suggested."). Not replayed on the corpus: the
replay tool is Rust and this backend lives in the Swift shell.

### llama-server vocabulary bias

`logit_bias` for the user's single-token words (one `/tokenize` call per profile) is in;
not yet measured against llama-server (the leave-one-out personalization replay with
`--backend llama-server` is the way to do it).

## How to reproduce

See `docs/DEVELOPMENT.md` (ft-replay section). For release notes, run the full corpus with
the default model and record the summary line here.
