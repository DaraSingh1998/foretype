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

The corpus has no typos, so every block or correction on it is a false one. Verdicts come
from the app's own `Speller` (via `tools/spell-map`) in the checker's current language,
en_IN, with `/usr/share/dict/words` as a second opinion on whether a fragment can still
become a word. Of 2,792 distinct fragments, 18 are "impossible": all names (Kaczynski,
Malbolge, Priya, Roblox, Hauts), which the core lets through as capitalized, except the
lowercase `malbolge` (a programming language). Autocorrect candidates: "apologize" →
"apologise" (the en_IN dictionary is British), "Baie" → "Babe" (a name at a sentence start
would be wrongly offered), "ROblox" → "Roblox" (mid-sentence, skipped as a name). Replay
with the verdicts: keystrokes saved unchanged at 41.9%; 4 requests blocked as typos and 2 corrections offered (both false, on a typo-free corpus; the simulated user ignores them). Spell-checker calls cost 0.1–1 ms each off the main
thread once warm (about 11 ms for the first).

Two earlier versions were wrong, and the hands-on run (below) caught both. With no
language passed, the checker accepted a word valid in *any* of the user's ~30 languages,
so "recie" passed. With only the checker's completion list, real words such as "vom…" and
"signu…" were blocked.

### Apple on-device model (`shell` backend)

`AppleModel.complete` with the core's request format, on this M3 Pro (macOS 27.0.1):
2.2 s for the first request, then 0.45–0.6 s; continuations were sensible ("closer to
agreement than the" → "previous discussion suggested."). Not replayed on the corpus: the
replay tool is Rust and this backend lives in the Swift shell.

### MLX against llama.cpp (experiment)

MLX 0.32.4 / mlx-lm 0.32.2 with `Qwen/Qwen3-1.7B-MLX-4bit` (the instruct model: no MLX
build of the base exists, and speed doesn't depend on it), against llama.cpp
(`llama-bench`, Homebrew 0.7.0) with Qwen3-1.7B-Base Q4_K_M, same day, same Mac. The MLX
keystroke loop (scratch script; 100 keystrokes of the email fixture, prefix-cache trim and
reuse like the engine, 8 greedy tokens, Python loop) is roughly what the engine does.

| | MLX 4-bit | llama.cpp Q4_K_M |
|---|---:|---:|
| Prompt, 512 tokens | 1,131 tok/s | 1,282 tok/s |
| Decode, 128 tokens | 98.1 tok/s | 93.7 tok/s |
| Keystroke loop, 8-token suggestion | p50 86 / p90 89 ms, 1-token prefill | engine: p50 70–77 ms for 4 words |

No reason to switch (D32).

### llama-server vocabulary bias

`logit_bias` for the user's single-token words (one `/tokenize` call per profile).
Leave-one-out over the 12 self-written documents, examples off (vocabulary bias only),
llama-server 0.7.0 with Qwen3-1.7B: off 40.7%, Balanced 41.0%, Strong 41.3% (in-process,
Phase 3: 41.0% → 41.2%). Small, as expected on documents that share few words.

## Pixel caret locator (2026-10-20)

### Synthetic (`Foretype --caret-selftest`)

30 rendered cases: Helvetica 13, Georgia 17, the system font 14 (2×), Menlo 12, Times New
Roman 12 (1×); 1 and 2 pt carets; accent blue on white, black on white (same colour as the
text), white on dark gray. Blink and verify find every caret; worst x error 0.00 pt (after
taking the caret colour from fully covered pixels and each column's median strength;
before, 1× Times with a 2 pt caret at a fractional x was off by 0.64–0.76 pt). No false
caret from `l`, `|`, `1` stems with the caret off, from identical frames, or from a word
typed between captures.

### TextEdit against its AX caret (`scripts/caret-measure.sh`)

M3 Pro, built-in Retina display (2×), macOS 27.0.1, development build under the terminal's
grants, new document from a fixture copy, caret moved with `AXSelectedTextRange` to the
middle and the end of the first 6 lines (12 positions), no keystrokes. The AX caret
(`prevEdge`) is correct in TextEdit, so it is the reference.

| Document | Blink found | Blink x / y error | Verify found | Verify x error | Advance error (host font) | Advance, fallback font: raw / learned scale |
|---|---|---|---|---|---|---|
| plain text, Menlo 11 | 12/12 | 0.00 / 0.00 pt (max 0.00) | 12/12 (1 capture) | median 0.29, max 0.54 pt | 0.00 pt | – |
| RTF, Helvetica Light 15 | 12/12 | 0.00 / 0.00 pt (max 0.00) | 8/12 (1 capture) | median 0.38, max 0.42 pt | 0.00 pt | median 7.8, max 9.3 / median 1.3, max 8.4 pt |

- TextEdit draws its caret centred on the AX insertion point, so the bar's weighted centre
  equals the AX x to 0.01 pt.
- Blink latency from a caret move: median 668–679 ms (6 captures), max 1.3 s (11 captures);
  the caret stays on for about 0.55 s after a move. One capture of the field (656 × 384 pt):
  median 42–54 ms, the first one 190–200 ms (ScreenCaptureKit's window list).
- Verify: median 43–63 ms for one capture of the ±24 pt region. The 4 misses were captures
  in the caret's off phase: a programmatic move does not always restart TextEdit's blink
  (blink then took 3 or 11 captures). Verify now takes up to 3 captures 250 ms apart.
- Advance: in TextEdit's own font the predicted x after the rest of a line is exact. In the
  fallback font (system font at 0.78 × the caret height, as GhostPanel uses when the host
  reports no font) it drifts 7.8 pt over about 200 pt; the width scale learned from the
  previous line (1.04 here) brings it to about 1.3 pt, and verify corrects the rest at the
  next short pause.

### LibreOffice Writer (`scripts/caret-measure.sh LibreOffice org.libreoffice.script scripts/fixtures/caret-lines.rtf`)

LibreOffice 26.8.0.3, same Mac and display, the RTF fixture opened from a copy, caret moved with
`AXSelectedTextRange` in each paragraph's own `AXTextArea` (12 positions in 6 paragraphs).

- Writer exposes one `AXTextArea` per paragraph. After a programmatic open it reports no
  `AXFocusedUIElement` at all (app or window), whatever is tried from outside (window raise,
  `AXFocused`, a selection change, `AXEnhancedUserInterface`, which it rejects), so the bench
  walks the window for paragraphs. Setting `AXSelectedTextRange` moves the real caret.
- Paragraph frames are 98 pt above the text (frame y 289, characters and caret at y 387),
  which is why `CaretResolver` rejected every rect. The zero-length rect is a sentinel.
- Blink found the caret 12/12 (median 451 ms, 4 captures; max 586 ms), verify 12/12 with one
  capture (median 47 ms), within 0.30 pt of blink.
- **The previous-character rects are right**: their trailing edge is 0.50 pt left of the
  caret's centre and 0.50 pt off vertically at all 12 positions (the caret is 1 pt wide and
  starts at the edge). So the locator now confirms such rects (two matches) and the app's
  rects are used from then on, at no capture cost (D24).
- The reported font is wrong for the screen: size 12 for text drawn with a 29–30 pt caret
  (the document is zoomed), so the width advance in that font was 205 pt off over a line, and
  in the fallback font 66 pt (21 pt with the learned width scale). `CaretResolver.font` now
  scales a font whose last characters are more than 25% wider or narrower on screen.

### Hands-on run (2026-10-21)

Development build (`FORETYPE_ONLY_APPS` set to the app or the test process), user off the
keyboard, new documents only:

- **TextEdit** (`scripts/e2e-typing-aids.sh`): all 6 checks pass. The emoji ghost `🎉 :tada:`
  sits right after `:tad` and Tab replaces the shortcode; `→ receive` is offered after
  "recieve " (TextEdit's own autocorrect fixes the word on the space as well); "zqxwv" ends
  in a policy hide; in "We should | the meeting to Thursday." with "m" typed, the card
  "⇥ ention that" appears under the caret and Tab gives "We should mention the meeting…".
- **Pixel caret in TextEdit** (`FORETYPE_CARET=pixel scripts/e2e-pixel-caret.sh TextEdit
  com.apple.TextEdit`): blink detection in 2–5 frames (165–564 ms), verify in one frame
  (116 ms), the ghost on the right line at the caret.
- **Fresh Chrome** (`scripts/e2e-chrome-fresh.sh`): suggestion shown (ghost "I think we
  can" after the caret, in the page's Georgia), primed again after the flag was cleared.
- **Chrome replacements** (`scripts/e2e-browser-aids.sh`): Tab turned `:tad` into 🎉 and
  fixed "recieve" (Chrome doesn't autocorrect, so this is Foretype's replace-on-Tab). The
  first run failed: the model suggested "rec" → "ieve the notes" and type-through carried
  the misspelling past autocorrect, so typing aids now run before type-through.
- **Text markers** (`MARKERS=1`): forcing the marker path in Chrome's textarea produced no
  text (Chrome answers none of the marker attributes there); Safari couldn't be tested (its
  focus stayed in the address bar). The fallback is unverified and harmless when markers
  are missing.
- **VS Code** (user clicked into the chat input): the field is `AXTextArea` labelled
  "Message input", which the guessed `allow_fields` patterns missed; added for VS Code,
  Cursor and Windsurf.
- Not done (screen control declined): LibreOffice with a real click, a Mail draft, Notes.

## About You (2026-10-22)

Qwen3-1.7B Q4_K_M, full corpus (53 documents, 12,704 characters), built-in engine, Metal,
4 words, greedy, prefetch on, instant simulated user. `eval/details.json` gives the three
self-written documents that end in a signature (Anna, Ravi, Emily) their fictional signer
and every other document one more fictional person, so the writer line names someone
unrelated to the text in 50 of 53 documents. A fill other than a name is taken only if all
of it comes next (one Tab inserts all of it).

| Run | Keystrokes saved | Chars per accept | Accepts | Model p50 / p90 | `details` events |
|---|---:|---:|---:|---:|---:|
| Before (main, `c295eb4`) | 41.9% | 3.68 | 1,985 | 80 / 118 ms | |
| After, no details | 41.9% | 3.68 | 1,985 | 73 / 99 ms | 0 |
| After, fills (`--details eval/details.json`) | 42.0% | 3.68 | 1,987 | 75 / 112 ms | 5 |
| After, fills + writer line (`--details-in-prompt`) | 42.2% | 3.69 | 1,991 | 76 / 108 ms | 5 |

- Without details the core behaves exactly as before (same accepts; one model request
  fewer from timing).
- The fills fire only where a signature follows a sign-off ("Best regards,\nAnna"): the
  name is offered on the empty line and Tab takes the first name in all three documents,
  where the model had guessed other names. The corpus has no "my email is" style text, so
  the other cues never fire on it; the unit tests cover them (`core/src/details.rs`).
- The writer line didn't hurt, even naming the wrong person in 50 documents (+0.2 points
  over fills alone, within run-to-run noise), so it ships on, with its own switch.
- On the 12 self-written documents alone (`--only sw-`): 41.0% → 41.1%.
- Latency differences are noise between runs (no change to the inference path); fills
  answer synchronously without the model.

Hands-on (`scripts/e2e-about-you.sh`, new unsaved TextEdit document, fictional details,
`FORETYPE_ONLY_APPS=com.apple.TextEdit`): 9/9 checks passed. "My email is " showed the
email with its "your email" tag and one Tab inserted all of it; "Call me on +91" showed
the rest of the number; after "Regards," Tab took "Priya" and accept-all " Raman"; "My
email is x" got no fill. The first run failed only the log check: the model itself had
suggested "Priya Raman" after reading the email address in the document, and model text
was logged as is. Pieces of the details are now masked in debug logs (`***`), and the
second run passed. Its screenshots also show a second gray suggestion overlapping the fill:
the developer's own Foretype.app (a main-branch build) was running and suggesting in
TextEdit at the same time.

## Inline ghost text while typing (2026-10-22)

Report: in an Electron chat composer (the Claude app) the suggestion first showed in a card
above or below the line and moved next to the caret only after a pause.

### What Chromium reports (probe, `scripts/fixtures/composer.html#ce,bg` in a background Chrome)

Chrome 155, throwaway profile, `AXEnhancedUserInterface` set, the fixture typing into its
contenteditable (one `<p>` per line), read every 150 ms:

| State | `AXNumberOfCharacters` | `AXSelectedTextRange` | `AXStringForRange(0, sel)` | `AXValue` |
|---|---:|---:|---|---|
| empty (`<p><br></p>`) | 1 | 1 | `"\n"` | `"\n"` |
| first line, "Thanks" | 6 | 6 | `"Thanks"` | `"Thanks"` |
| second paragraph, "…works" ⏎ "Could we move" | 124 | 123 | `"…worksCould we move"` | `"…works\nCould we move"` |
| list item under a paragraph, "…see" ⏎ "1. Power " | 40 | 39 | `"…see1. Power "` | `"…see\n1. Power "` |

- The ranges leave out the newline between paragraphs that the value and the count have.
  `AXStringForRange(sel, count − sel)` fails, so Foretype read the text after the caret from
  `AXValue` at the range index: the last letter typed. Debug log before the fix: `after=a`
  on every suggestion in the second paragraph and the list item.
- No text markers (`AXSelectedTextMarkerRange` absent) and `AXBoundsForRange` returns
  `0,982 0x0`, so there is no AX caret: the pixel locator places the ghost text.
- List markers ("1. ") are in both the ranges and the value.

### Chat-composer fixture in Foretype (`scripts/e2e-inline-caret.sh ce`)

Development build, `FORETYPE_ONLY_APPS` = the test Chrome's pid, `FORETYPE_CARET=pixel`,
Gemma 4 E2B Q4_K_M, M3 Pro at 2×. The page types at 110–190 ms per character with no pause
inside a segment. Counted: every non-empty suggestion drawn (model, type-through, pixel
moves).

| Segment | Before: inline / card / mirror | Card→inline jumps | After: inline / card / mirror | Jumps |
|---|---|---:|---|---:|
| 1 empty composer, first line wraps | 1 / 0 / 37 | 1 | 47 / 0 / 0 | 0 |
| 2 Enter, second line | 2 / 5 / 1 | 2 | 9 / 0 / 0 | 0 |
| 3 sent (emptied), new first line | 1 / 0 / 9 | 1 | 10 / 0 / 0 | 0 |
| 4 numbered list item | 1 / 4 / 5 | 1 | 24 / 0 / 0 | 0 |
| 5 new field, typed 0.2 s after focus | not reached | | 20 / 0 / 0 | 0 |

- Before (main `24532d2` plus the debug fields; the run stopped in segment 5 when the user
  came back): the only inline draws were a pause's blink moving the suggestion (once per
  segment) and one suggestion right after a typed space (`after=U+0020`). Segment 1 had a
  blink at focus but lost it: the empty composer read as `"\n"` (line 2), the first letter
  as line 1. The second paragraph and the list item drew the card under the caret
  (`after=a`, the bug report's picture); once the glued text wrapped past the field's edge,
  the mirror card. A later partial run (segment 1 only) drew 32 of 32 as the mirror card.
- After (one full run; two more stopped early when the user came back, with 26 of 26 and
  44 of 44 inline in segment 1): every suggestion inline. In the full run the locator ran a
  blink at focus on the empty composer (921 ms, before typing started), then solid searches
  only: 2 near the right edge on the same row and 1 on the wrapped row (62–101 ms each), 1
  after Enter (53 ms), 3 near the edge of the second line, 1 when the field was emptied, 1
  for the list item (44 ms), 1 on focus of the new field (115 ms, as typing started) and 1
  near its edge. Pause verifies found the caret within 1 pt of the extrapolated position
  (316 vs 315, 290 vs 289, 479 vs 480).
- Screenshots taken right after a suggestion was drawn show the gray ghost text right after
  the caret on its line. The developer's installed 0.1.0 also ran on the test Chrome and
  shows the old behaviour in the same shots: its mirror card above the field, and in the
  list item its card under the line at a wrong x.
- Self-tests: `--caret-selftest` adds 8 bar-choice, 6 index-mapping and 4 caret-lag cases,
  all pass (30 rendered cases unchanged, worst error 0.00 pt); `--font-selftest`,
  `--ocr-selftest` and `cargo test` (51) pass.

### The Claude app by hand

Development build restricted to `com.anthropic.claudefordesktop`, no `FORETYPE_CARET`
override, the installed Foretype quit; the user typed in a new chat draft (a line long
enough to wrap, Shift+Return, a numbered list) and discarded it. The Claude app gives no AX
caret either, so the pixel locator placed every suggestion.

- 50 suggestions drawn: 47 inline, 3 as the card under the caret, no mirror card. A blink
  found the caret when the empty composer got focus (435 ms), before the first keystroke.
- 14 pause verifies found the caret 0–3 pt from the extrapolated position (median 1 pt).
- Each of the 3 cards lasted 6–28 ms: a snapshot in which Electron had put the typed letter
  into the text but not yet moved the caret index (`after=a`, caret x unchanged), followed
  by the corrected snapshot, drawn inline. `FocusTracker` now holds such a snapshot once and
  reads the field again 17 ms later; not yet re-run in the app.
- The composer grows upward: every caret position had the same y. 3 solid searches found no
  caret and the estimate stayed in use; that log had no line starts or field frames, so
  whether a new line was found by the solid search or only at the next pause can't be told.
  The debug line now has `line=` and `field=`.

## Default instructions (2026-10-22)

Gemma 4 E2B Q4_K_M (the only model installed on the developer's Mac that day), full corpus
(53 documents, 12,704 characters), built-in engine, Metal, 4 words, greedy, prefetch on,
instant simulated user, `ft-replay --instructions FILE` (or `--default-instructions`). The
notes go into the prompt as `[Writer's notes: …]`.

| Notes | Keystrokes saved | Chars per accept | Accepts |
|---|---:|---:|---:|
| None (as before; matches the 2026-10-20 row exactly) | 42.8% | 3.78 | 1,954 |
| "Natural, clear writing that matches the tone of the text so far, with correct spelling and grammar." | **43.5%** | 3.80 | 1,972 |
| "Write naturally and clearly. Match the tone of the text so far. Use correct spelling and grammar." | 43.3% | 3.80 | 1,967 |
| "Clear, natural writing in the same tone and language as the text so far." | 43.2% | 3.79 | 1,966 |
| "I write plainly and naturally, keep the tone of what I have written so far, and use correct spelling and punctuation." | 42.9% | 3.77 | 1,967 |
| The first note + per-app notes (email, chat, notes, documents, ...) | 43.3% | 3.79 | 1,972 |
| Per-app notes alone | 42.7% | 3.79 | 1,949 |
| Shipped defaults (`--default-instructions`), second run | 43.5% | 3.80 | 1,972 |

- Every note for all apps helped; the descriptive one most (+0.7 points), and a second run
  of it gave the same numbers, so it ships as the default.
- Per-app style notes ("Email: polite, clear and to the point.", "Chat: short, casual
  messages, the way people text.", ...) didn't: on the 11 documents from a named app (the
  others are "a chat app" or "a browser", which have no bundle ID) they helped 3 and hurt 5
  against the global note alone (`sw-chat-4` 46.2% → 42.5%, `sw-essay-1` 44.6% → 42.9%). The
  app is already named in `[Written in …]`. None ship.
- Not measured on the Qwen models (not installed). Latency is unchanged: the notes are part
  of the cached header, prefilled once per field.

Apple's on-device model (the `shell` backend), 106 points from the corpus (two per document,
at word boundaries about a third and two thirds in), greedy, a prompt of `[Written in APP]`,
the optional notes line and the text before the point, scored on whether its first word is
the word that came next:

| Instructions | Notes | First word right | Words right per point |
|---|---|---:|---:|
| Current ("You continue the user's text exactly where it stops. …") | none | 17.0% | 0.20 |
| Current | default note | **19.8%** | 0.23 |
| Reworded (bracketed lines are context, follow the notes, same language and tone) | none | 17.9% | 0.20 |
| Reworded | default note | 19.8% | 0.23 |

- The default note helps the Apple model too; reworded instructions didn't add anything with
  it, so they were not changed.

## Models for Hindi and Hinglish (2026-10-22/23)

Every catalog model on the Hindi (Devanagari, 13 documents, 4,616 characters) and Hinglish
(Roman script, 12 documents, 3,632 characters) corpora of `eval/README.md`, with the English
corpus as a control. Built-in engine at `main` fec132f (before the virama, nukta and danda
fixes of `fix/hindi-hinglish`), Metal, 4 words, greedy, prefetch on, instant simulated user,
no instructions. The first pass shared the GPU with another session's `ft-replay`, so the
Hindi and Hinglish latencies below come from a second pass that started only with no other
`ft-replay` running and checked every 2 s that none started; all of it on mains power except
Qwen3-0.6B's second pass (battery, marked \*). English latencies are the 2026-10-20 row
above (the English savings reproduced it: 39.9%, 41.9%, 42.8% and 44.9% against 45.0%).

| Model | Hindi saved | Chars per Tab | Hindi p50 / p90 | Hinglish saved | Chars per Tab | Hinglish p50 / p90 | English saved | English p50 / p90 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Qwen3-0.6B Q8_0 | 20.0% | 2.47 | 171 / 222 ms\* | 10.8% | 2.47 | 74 / 114 ms\* | 39.9% | 46 / 61 ms |
| Qwen3-1.7B Q4_K_M (default) | 27.7% | 2.76 | 244 / 298 ms | 15.1% | 2.61 | 108 / 148 ms | 41.9% | 73 / 101 ms |
| Gemma 4 E2B Q4_K_M | **34.2%** | 3.24 | **125** / 340 ms | **27.7%** | 3.24 | 126 / 172 ms | 42.8% | 109 / 159 ms |
| Qwen3-4B Q4_K_M | 32.5% | 2.95 | 369 / 383 ms | 23.0% | 3.17 | 207 / 276 ms | 44.9% | 147 / 203 ms |

Tokenizer cost of the corpus text (`ft-replay --token-cost`; the three Qwen3 sizes share
one vocabulary):

| Vocabulary | Hindi chars / token | Hindi tokens / word | Hinglish chars / token | Hinglish tokens / word | English tokens / word |
|---|---:|---:|---:|---:|---:|
| Qwen3 (151k) | 1.06 | 4.57 | 3.26 | 1.64 | 1.16 |
| Gemma 4 (262k) | 3.70 | 1.31 | 3.89 | 1.38 | 1.17 |

- Gemma 4 E2B is the best model for both: on Hindi 6.5 points above the default Qwen3-1.7B
  and 1.7 above Qwen3-4B, on Hinglish 12.6 and 4.7 points above them, although Qwen3-4B
  leads it on English by 2.1. Gemma keeps 80% of its English savings on Hindi (34.2 / 42.8),
  Qwen3-1.7B 66%; its correct words are also longer (3.24 characters per Tab against 2.76).
- Qwen3's vocabulary spends about one token per Devanagari character (4.57 per word, 3.5
  times Gemma's), so on Hindi it is the slow one: p50 244 ms for 1.7B and 369 ms for 4B
  against Gemma's 125 ms, the reverse of English. p50 and p90 are close for Qwen3 on Hindi,
  which fits most suggestions running into the decode cap (`max_words * 3 + 8` tokens plus
  the fragment's bytes, 21 at a word start, against about 18 for four Hindi words): the ghost
  text is likely shorter, but keystrokes saved don't depend on it, since the simulated user
  takes one word per Tab and waits for the next suggestion.
- Gemma's Hindi p90 (340 ms, the same in both passes) is well above its Hinglish p90; not
  investigated.
- Hinglish is harder than Hindi for every model: romanized spellings vary (achha / accha,
  nahi / nahin) and the language switches mid-sentence. The 0.6B model nearly gives up on it.
- Repeatability: both passes gave identical counts for Gemma, Qwen3-0.6B and Qwen3-1.7B on
  Hinglish; Qwen3-1.7B Hindi gave 27.6% then 27.7%, Qwen3-4B Hindi 32.2% (852 accepts) then
  32.5% (767 longer ones). Whether a word comes from a prefetch, type-through or a fresh call
  depends on timing. Gemma's lead is larger than that spread.
- Limits: small corpora written by one author for this test, one simulated (ideal) user, two
  passes. `fix/hindi-hinglish` measured +0.3 points on Hindi for Qwen3-1.7B from keeping
  virama and nukta words whole and stopping at a danda; not re-run here for the other models.

```bash
R=core/target/release/ft-replay; M="$HOME/Library/Application Support/Foretype/Models"
for f in Qwen3-0.6B-Base.Q8_0 Qwen3-1.7B-Base.Q4_K_M gemma-4-E2B.Q4_K_M Qwen3-4B-Base.Q4_K_M; do
  for c in eval/corpus-hi.jsonl eval/corpus-hinglish.jsonl eval/corpus.jsonl; do
    $R "$M/$f.gguf" --corpus $c --token-cost
    $R "$M/$f.gguf" --corpus $c
  done
done
```

## Pause and power (2026-10-22)

Apple M3 Pro, 18 GB, macOS 27.0.1, on mains power; the dev bundle (`build/Foretype.app`,
`feat/pause`) with gemma-4-E2B Q4_K_M (the only model installed), restricted to TextEdit
(`FORETYPE_ONLY_APPS`), Screen Recording granted. CPU is the process's CPU time over the
window (`ps -o time`; GPU work is not in it), idle wakeups the change in `top`'s IDLEW
(wakeups that pulled a CPU out of idle), memory the resident size. `sudo powermetrics` was not
run (it needs the user's password).

`scripts/e2e-pause.sh` (`TYPE=1 SAMPLE=20`), 20 s per phase: **PASS**. Caret moves through
Accessibility gave 5 suggestion lines before the pause, 0 suggestion, priming, screen or
pixel-caret lines while paused (caret moves, TextEdit opened again), 6 after
`foretype://resume`; the core logged `engine paused: model unloaded` 0.1 s after the URL
and loaded the model again on the first suggestion after the resume (1.7 s);
`pause?minutes=0.1` resumed by itself after 6.6 s.

| Phase (20 s) | CPU | Idle wakeups | Memory |
|---|---:|---:|---:|
| Typing in TextEdit, 7 characters/s | 2,600 ms | 37 | 3,396 MB |
| In a field, not typing (model loaded) | 190 ms | 21 | 3,337 MB |
| Paused | 70 ms | 6 | 62 MB |

60 s per phase, another app in front (Foretype reads nothing there but runs its 0.5 s
poll), the user working meanwhile:

| Phase (60 s) | CPU | Idle wakeups | Memory |
|---|---:|---:|---:|
| Running, model loaded (what "Suggestions Off" cost before: it only gated the core) | 510 ms | 46 | 3,282 MB |
| Paused | 200 ms | 55 | 73 MB |
| Running, `GGML_METAL_NO_RESIDENCY=1` | 110 ms | 0 | 1,831 MB |
| Paused, `GGML_METAL_NO_RESIDENCY=1` | 50 ms | 0 | 74 MB |

- Pausing frees the model (3.3 GB resident with gemma-4-E2B → 62–73 MB) and stops all of
  Foretype's own work: the main thread used no CPU over 40 s of pause (`ps -M`).
- What remains while paused is llama.cpp's Metal residency-set heartbeat
  (`ggml_metal_rsets_init` in `ggml-metal-device.m`): a thread on the default global queue
  that sleeps 5 ms and loops for the life of the process, whether a model is loaded or not,
  requesting residency only during the 3 minutes after a computation. The Metal device it
  belongs to is a process-wide singleton, so freeing the model can't stop it; only
  `GGML_METAL_NO_RESIDENCY`, read when the device is first created, can. Without it the
  idle cost falls to 110 ms per minute running and 50 ms paused, with no idle wakeups.
  Turning residency sets off may let macOS page the model's GPU buffers out between bursts
  of typing; that latency hasn't been measured, so it is not changed here.

## Ghost font size in TextEdit (2026-10-22)

`CaretResolver.font` read at every caret position of two test documents (a scratch probe
calling it over Accessibility, nothing typed), before and after the fix:

| Document | Positions | Before | After |
|---|---|---|---|
| RTF from `textutil -font Helvetica -fontsize 20` (Helvetica Light 20), 800×190 pt window | 102 | 97 right; 5 at 74–80 pt (the last 24 characters crossed a soft wrap: rect 773×48 pt) | all Helvetica-Light 20 |
| Plain text (Menlo) set to 20 pt by AppleScript, last 44 characters at 12 pt, 760×200 pt window | 147 | 111 right; 23 at 50 pt (soft wrap), 13 at 15–19 pt (20 pt and 12 pt measured together) | 103 at Menlo 20, 44 at Menlo 12 |

Before the fix the font was also read only once per line, before typing, so the 12 pt text
typed after the 20 pt text got a 20 pt ghost. Live run (dev build, Qwen3-0.6B, synthetic
typing in both documents, `FORETYPE_DEBUG` logs the font): every suggestion in the RTF was
drawn in Helvetica-Light 20 and every one after the typed text in the plain-text document in
Menlo-Regular 11, the size the text was typed in.

## Hindi and Hinglish (2026-10-22)

`ft-replay` with Qwen3-1.7B-Base Q4_K_M, default settings (4 words, stop at sentence end),
before (`main` at fec132f) and after branch `fix/hindi-hinglish`. The Hindi and Hinglish
corpora are drafts from the eval-corpus work (12 Hinglish and 13 Devanagari documents,
copied on 2026-10-22 before they were committed); the spell verdicts come from
`tools/spell-map` with the checker in en_IN. Every document is typo-free, so every
correction and every typo block is a false one. Another `ft-replay` shared the GPU during
the English runs and the last Hinglish run, so their latency is noisy; keystroke counts
don't depend on timing.

| Corpus | Keystrokes saved | False fixes | Typo blocks | Model p50 |
|---|---:|---:|---:|---:|
| Hinglish, before | 14.2% | 172 | 188 | 173 ms |
| Hinglish, after (list written before seeing the corpus) | 15.1% | 4 | 4 | 181 ms |
| Hinglish, after + 5 words from this corpus | 15.1% | 0 | 0 | 207 ms |
| Hindi (Devanagari), before | 27.4% | 0 | 0 | 353 ms |
| Hindi (Devanagari), after | 27.7% | 0 | 0 | 352 ms |
| English `eval/corpus.jsonl`, before | 41.9% | 2 | 4 | 133 ms |
| English `eval/corpus.jsonl`, after | 41.9% | 2 | 4 | 141 ms |

- The spell checker flags 181 of the 1,000 distinct Hinglish fragments as impossible and
  116 of its words as misspelled ("hain" → "hair", "kuch" → "such", "tum" → "sum",
  "jaldi" → "naldo"); it flags no Devanagari at all.
- The 8 left after the first list were early words of a message, before two listed words
  had been typed (phas, bana, lete, pichle, mahine). The user chose to add them; the row
  with them is measured on the corpus they came from, so it is not an independent number.
- Hinglish detection (two listed words among the last 40) holds at 614 of the 671 word
  positions of the Hinglish corpus, from the 2nd to the 14th word of each document, and at
  none of the 2,334 positions of the English corpus, where no listed word occurs.
- Hindi gains 0.3 points from the danda stopping suggestions at sentence ends and from
  words with a virama or nukta staying whole.
- Hindi is about twice as slow as Hinglish because of the tokenizer: Qwen3 spends 4.57
  tokens per Devanagari word against 1.64 for Hinglish (नहीं 5 tokens, "nahi" 2), and a
  suggestion is limited in words; gemma-4-E2B spends 1.31 (`llama-tokenize`).

## Cross-app context baseline (2026-10-23)

Phase A of the cross-app context plan (`docs/ROADMAP.md`, D42), before any reading of other
apps is built: what text from another app's window is worth, and what a longer context
costs. `scripts/bench-context.sh` at c9763a9 on `feat/context-baseline`, one run after
another with no other `ft-replay` on the GPU (the script checks), on AC power, every
catalog model (Qwen3 files from the Phase 0 folder, sha256 equal to the catalog's; nothing
downloaded).

### Keystrokes saved with another app's text

`eval/corpus-multiwindow.jsonl` (21 documents, 9,783 characters; `eval/README.md`), built-in
engine, Metal, n_ctx 2048, 4 words, greedy, prefetch on, instant simulated user, no
instructions. The context goes in as screen text (`--context-mode`): *focused* is the
focused window's own text (the email being answered, the chat so far; 24–252 characters),
*other* the other app's (272–687 characters), *both* the other app's then the focused
window's, under today's 1,500-character cap. *First* is each document's first model
suggestion, which prefills the whole header.

| Model | None | Focused | Other | Both | Chars per Tab, none → both | Model p50 / p90, none → both | First p50 / p90: none, focused, both |
|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen3-0.6B Q8_0 | 34.7% | 38.3% | 56.8% | **58.4%** | 3.59 → 4.63 | 54 / 90 → 53 / 84 ms | 40 / 64, 55 / 82, 88 / 111 ms |
| Qwen3-1.7B Q4_K_M (default) | 38.7% | 41.6% | 59.5% | **60.9%** | 3.75 → 4.73 | 86 / 140 → 79 / 122 ms | 77 / 114, 103 / 140, 201 / 227 ms |
| Gemma 4 E2B Q4_K_M | 40.7% | 43.7% | 59.1% | **60.9%** | 3.77 → 4.72 | 120 / 192 → 118 / 193 ms | 90 / 120, 147 / 234, 300 / 324 ms |
| Qwen3-4B Q4_K_M | 40.7% | 44.8% | 61.0% | **62.5%** | 3.85 → 4.80 | 155 / 242 → 187 / 304 ms | 86 / 171, 201 / 272, 398 / 497 ms |

- The other app's text is worth about 20 points on every model (focused → both: +20.1,
  +19.3, +17.2, +17.7), five times what the focused window adds on this corpus. With it the
  smallest model (58.4%) beats the largest without it (44.8%).
- The gain is in the words that come from the other window (figures, dates, names, steps):
  characters per Tab rise by about one, and the model is called less (1.7B: 2,749 → 1,320
  calls) because more of the text is typed through.
- Per-keystroke latency doesn't change at this size (the context sits in the cached
  prefix); the first suggestion does, by the prefill of 110–290 more tokens (median 150,
  Qwen3 tokenizer; 1.7B: 77 → 201 ms p50). In the app the shell prefills a new header as soon as OCR finishes (`warm`),
  so typing usually doesn't wait for it.
- Limits: a best case, like the chat-reply sample of Phase 1+: every document was written
  to quote its other window, the context is clean text (OCR would add noise; Accessibility
  text would be close to this), and it is exactly the right window, so relevance ranking
  (Phase C) has nothing to get wrong yet. One pass per cell; earlier corpora repeated
  within about 0.3 points.

### Longer context: latency and memory (`ft-replay --ctx-bench`)

One process per model and n_ctx. For each of the 21 documents, a prompt whose screen
section holds other corpus text, then the document's `context` and `screen`, filled to 90%
of the window (prompt p50 1,835 / 3,671 / 7,336 tokens); 40 characters of the reply typed
before the first suggestion, from an empty cache; then the next 40 keystrokes reusing the
cache. Memory is this process's (`proc_pid_rusage`): *resident* counts the memory-mapped
model pages it touched, *footprint* (Activity Monitor's Memory) is dirty memory: KV cache,
compute buffers, Metal allocations.

| Model | n_ctx | First suggestion p50 / p90 | Prompt ÷ first | Keystrokes p50 / p90 | Resident, loaded | Footprint, loaded / peak |
|---|---:|---:|---:|---:|---:|---:|
| Qwen3-0.6B | 2048 | 646 / 683 ms | 2,840 tok/s | 53 / 100 ms | 968 MB | 386 / 416 MB |
| | 4096 | 1,521 / 1,554 ms | 2,410 tok/s | 64 / 115 ms | 1,192 MB | 610 / 644 MB |
| | 8192 | 4,109 / 4,154 ms | 1,790 tok/s | 91 / 161 ms | 1,640 MB | 1,058 / 1,100 MB |
| Qwen3-1.7B | 2048 | 1,544 / 1,557 ms | 1,190 tok/s | 75 / 136 ms | 1,415 MB | 386 / 429 MB |
| | 4096 | 3,398 / 3,437 ms | 1,080 tok/s | 87 / 157 ms | 1,637 MB | 609 / 656 MB |
| | 8192 | 7,612 / 7,777 ms | 960 tok/s | 109 / 190 ms | 2,086 MB | 1,058 / 1,113 MB |
| Gemma 4 E2B | 2048 | 2,193 / 2,306 ms | 840 tok/s | 112 / 193 ms | 3,297 MB | 264 / 335 MB |
| | 4096 | 4,631 / 5,211 ms | 790 tok/s | 122 / 281 ms | 3,403 MB | 315 / 381 MB |
| | 8192 | 9,463 / 10,037 ms | 780 tok/s | 112 / 199 ms | 3,487 MB | 387 / 470 MB |
| Qwen3-4B | 2048 | 3,965 / 4,372 ms | 460 tok/s | 156 / 304 ms | 2,734 MB | 449 / 506 MB |
| | 4096 | 8,614 / 9,628 ms | 430 tok/s | 172 / 317 ms | 3,016 MB | 742 / 803 MB |
| | 8192 | 19,936 / 20,350 ms | 370 tok/s | 206 / 343 ms | 3,455 MB | 1,303 / 1,374 MB |

- **A full window is far too slow to wait for.** The first suggestion after a context change
  takes 0.6–20 s with a full window; prefill slows as the prompt grows (attention is
  quadratic without flash attention: 1.7B 1,190 → 960 tok/s). The header this corpus fills
  (up to 1,450 characters of screen text, at most 290 tokens) costs 90–400 ms (*First*
  above). A bigger context section is
  only usable with the prefill off the typing path (Phase D: prefill in the background on a
  second sequence, keep KV states per context) and a token budget well under the window.
- **Typing against a long context gets slower too**, because every decode step attends to
  the whole cache: keystroke p50 from 2048 to 8192 rises 72% on Qwen3-0.6B, 45% on 1.7B and
  32% on 4B. Gemma 4 E2B stays flat (112 ms): most of its layers use a 512-token sliding
  window, so only its few global layers see the whole context.
- **Memory grows with n_ctx exactly as the f16 KV cache predicts**: 112 KB per token for
  Qwen3-0.6B and 1.7B (28 layers × 8 KV heads × 128 × K and V × 2 bytes), so +224 MB at
  4096 and +672 MB at 8192 over 2048; 144 KB per token for Qwen3-4B (36 layers): +293 and
  +854 MB. Gemma 4 E2B grows only 51 and 123 MB (about 25 KB per token). A q8_0 KV cache
  (Phase D) would halve the growth.
- **The 8 GB question.** An 8 GB Mac gets Qwen3-0.6B by default and may choose Qwen3-1.7B;
  Gemma 4 E2B and Qwen3-4B need 16 GB (`models/catalog.json`). Engine memory for those two
  (resident, which includes the mapped weights; the Swift shell and OCR come on top):

  | n_ctx | Qwen3-0.6B | Qwen3-1.7B | Context it holds (about 4 characters per token, minus the body) |
  |---:|---:|---:|---|
  | 2048 (today) | 0.97 GB | 1.42 GB | ~1,500 characters of screen text (today's cap) plus the body |
  | 4096 | 1.19 GB (+0.22) | 1.64 GB (+0.22) | ~8,000 characters more |
  | 8192 | 1.64 GB (+0.67) | 2.09 GB (+0.67) | ~24,000 characters more |

  At 4096 the feature costs an 8 GB Mac about 0.22 GB more than today (0.11 GB with a q8_0
  KV cache); at 8192, 0.67 GB (0.34 GB). The pool's text itself is small (10 minutes of
  windows: tens of kilobytes). OCR of more windows costs CPU and energy, not much memory.
  Decided (D42): 8 GB Macs get the feature with Accessibility text only, a 512-token
  other-app section and n_ctx kept at 2048, so no extra KV memory; with a q8_0 KV cache
  (Phase D) n_ctx 4096 would cost what 2048 costs today.
- `prefill_ms` as the engine reported it here stopped when the last batch was submitted:
  llama.cpp runs that batch on the GPU asynchronously and waits for it at the first logits
  read, so its time showed up as generation (first suggestion minus prefill: 4B at 2048,
  741 ms). The engine's 300 ms generation deadline therefore started before a cold prefill
  had finished and cut the first suggestion after a long prefill short (1.7B at 2048 and
  8192: the generation phase ran into the deadline). The table uses the first suggestion's
  total time for that reason. Fixed since: the engine waits for the GPU at the end of the
  prefill (*Prefill timed in full* below).
- The app itself, measured on 2026-10-22 (*Pause and power*), was 3.3–3.4 GB resident with
  Gemma 4 E2B, in line with this table's 3.3 GB for the engine alone.

```bash
scripts/bench-context.sh            # every installed catalog model, n_ctx 2048 4096 8192
R=core/target/release/ft-replay; M="$HOME/Library/Application Support/Foretype/Models"
$R "$M/Qwen3-1.7B-Base.Q4_K_M.gguf" --corpus eval/corpus-multiwindow.jsonl --context-mode both-screen   # "both" before Phase C
$R "$M/Qwen3-1.7B-Base.Q4_K_M.gguf" --corpus eval/corpus-multiwindow.jsonl --ctx-bench --n-ctx 4096
```

### Prefill timed in full (2026-10-23)

`Engine::sync` now calls `LlamaContext::synchronize()` after the prompt's last batch, so
`prefill_ms` includes that batch's GPU time and the 300 ms generation deadline starts once
the prompt is read (efb4043). The same runs as above (`scripts/bench-context.sh` with
`MODES=both`, Qwen3-1.7B at n_ctx 2048, 4096 and 8192, Qwen3-4B at 2048), before (a366aa0:
the old engine, with `--ctx-bench` reporting the first suggestion's generation phase, its
words and deadline cuts) and after (efb4043), one run after another on AC power. *Generation*
is the first suggestion's time after `prefill_ms`; *cut* counts the first suggestions (of
21) that stopped at the deadline.

| Model | n_ctx | First suggestion p50 / p90 | Prefill p50 | Generation p50 | Words p50 | Cut |
|---|---:|---:|---:|---:|---:|---:|
| Qwen3-1.7B | 2048 | 1,549 / 1,561 → 1,595 / 1,747 ms | 1,241 → 1,526 ms | 309 → 64 ms | 1 → 4 | 15 → 0 |
| | 4096 | 3,376 / 3,525 → 3,504 / 3,772 ms | 3,183 → 3,386 ms | 182 → 71 ms | 4 → 4 | 0 → 0 |
| | 8192 | 7,664 / 7,730 → 7,653 / 7,874 ms | 7,354 → 7,566 ms | 313 → 85 ms | 2 → 4 | 14 → 0 |
| Qwen3-4B | 2048 | 3,911 / 4,311 → 4,034 / 4,241 ms | 3,193 → 3,909 ms | 719 → 119 ms | 1 → 4 | 21 → 0 |

- **The first suggestion after a long prefill is whole again, in about the same time.**
  Before, most of them stopped after one or two words: the generation phase began with the
  GPU still on the last batch, and with the deadline counted from there, little or none of
  it was left for generating. Now every one runs to its 4 words, and where they were cut
  before the total changes by −11 to +123 ms (at most 3%): the GPU time that was counted
  as generation is counted as prefill, and the extra words cost 50–100 ms. At 4096 nothing
  was cut before either
  (3,671 tokens leave a last batch of 87 after seven of 512, so little was left to wait
  for), and the +128 ms there is the difference between runs: a second pair, run one
  after the other, gave 3,356 / 3,399 ms before and 3,361 / 3,553 ms after (prefill
  3,170 → 3,278 ms, generation 187 → 70 ms).
- **True prefill rates**: Qwen3-1.7B 1,204, 1,084 and 970 tok/s at 2048, 4096 and 8192
  (reported before: 1,478, 1,154, 997), Qwen3-4B 470 (573). They match what the table
  above derived from the first suggestion's total (1,190, 1,080, 960; 460). Decode per
  generated token, which counted the GPU wait before, is now 12.7–17.0 ms on 1.7B (was
  38–104) and 24.0 ms on 4B (719).
- **Typing doesn't change**: a keystroke's prefill is a few tokens, done long before the
  deadline matters. `eval/corpus.jsonl` with Qwen3-1.7B: 41.9% → 41.9% keystrokes saved,
  3.68 → 3.68 characters per Tab, 1,985 → 1,986 accepts, model p50 / p90 79 / 109 →
  79 / 114 ms, first suggestion 62 / 93 → 63 / 97 ms, 3,063 → 3,066 model calls; the old
  engine again: 41.9%, 1,985 accepts, 80 / 121 ms, 64 / 105 ms, 3,064 calls. The
  multi-window corpus with both contexts: Qwen3-1.7B 60.9% → 60.9% (first suggestion
  199 / 231 → 205 / 226 ms); Qwen3-4B 62.5% → 62.7% (within the 0.3 points runs repeat
  to), its first suggestion 389 / 499 → 479 / 555 ms: on 4B the header's prefill (up to
  290 tokens) is slow enough that waiting for its last batch used to eat into the
  deadline. Keystroke latency differs by up to 10% between runs here (other work on the
  Mac), so only the keystrokes saved compare closely.

### A second display above the main one (by log and screenshot)

The developer's Mac: the built-in Retina display (1512×982 points, 2x) is the main one, a
BenQ GW2490 (1920×1080, 1x) is arranged above it (global y −1080 to 0). Qwen3-1.7B, with
`FORETYPE_ONLY_APPS`, on `feat/context-baseline`; `--geometry-selftest` converts both
displays' global frames to exactly their `NSScreen` frames. The log line
`show=… at X,Y` is the panel's frame as AppKit placed it.

| Check | Result |
|---|---|
| TextEdit on the BenQ (`e2e-textedit.sh`, `WINDOW_BOUNDS=100,-900,1000,-450`) | 60 of 60 suggestions inline, the panel's origin equal to the caret's every time (caret 865,−674 → panel at 865,−674); Tab, accept-all, Esc and Option+Tab as on the main display |
| Screen context of that window | Before: the window was captured at 2x. After it moved to the BenQ, the capture found the window by its frame at focus time and took TextEdit's empty Untitled window on the main display instead (81 characters of toolbar and ruler); right after, the model suggested `[End of screen t…`, echoing the header's marker. After the fixes: the moved window at 1x, 900×450 px |
| Chrome composer on the BenQ (`e2e-inline-caret.sh ce`, `WINDOW_POS=100,-950`, pixel caret) | Caret found by its blink in 176 ms at 1x (width scale 1.00), then by single captures in 39–59 ms; 199 suggestions inline over three segments (wrap 109, new line 72, list 29; the run stopped there when the keyboard or mouse was used); screen context 1000×600 px at 1x |
| Mirror card on the BenQ | Above the field: panel at 157,−791, field top −762. The old rule (y < 0 → below) would have put it under the field |

In one of the two runs with the new window matching, the moved window was missing from
ScreenCaptureKit's list at the moment of capture and the fallback still took the nearest
window; with a field known, the capture now skips instead. Not checked by eye: a
full-screen app on the BenQ with this branch (the full-screen capture of D43 was checked
in WhatsApp Web, next section), a window across both
displays (covered by the self-test's display matching), and switching Spaces.

## Cross-app context: the real section (2026-10-23)

Phases B and C (`feat/context-pool`, D44): the other app's text now reaches the prompt as
the core's own other-apps section (`ft_engine_set_context`, passages ranked into a token
budget, `[Also open: App — Title]` at the head of the prompt) instead of Phase A's stand-in,
which pasted it into the screen text. `ft-replay --context-mode other|both` sends each
document's other window as a pool with one window on screen; `other-screen|both-screen`
are Phase A's stand-in, rerun on the same build. Same corpus and conditions as the
baseline (21 documents, n_ctx 2048, 4 words, greedy, prefetch, instant user, no
instructions, budget 512 tokens), Apple M3 Pro, 18 GB, macOS 27.0.1, AC power, one run at
a time.

| Model | None | Focused | Other: stand-in → section | Both: stand-in → section | Both, 3 distractors | Section changes (both) |
|---|---:|---:|---:|---:|---:|---:|
| Qwen3-0.6B Q8_0 | 34.7%* | 38.3%* | 56.8% → 56.8% | 58.4% → **58.8%** | 58.4% | 21 |
| Qwen3-1.7B Q4_K_M (default) | 38.7% | 41.6% | 59.5% → 59.0% | 60.9% → **61.1%** | 61.3% | 21 (one per document) |
| Gemma 4 E2B Q4_K_M | 40.7%* | 43.7%* | 59.1% → 58.7% | 60.9% → **60.9%** | 60.7% | 21 |
| Qwen3-4B Q4_K_M | 40.7%* | 44.8%* | 61.0% → 61.1% | 62.7% → **62.9%** | 62.8% | 21 |

\* From the Phase A table (not rerun: nothing in those paths changed); 1.7B's none and
focused rerun here gave Phase A's numbers exactly.

- **Same gain as the best case, with the machinery a real pool needs.** The section saves
  as much as pasting the right window into the prompt did: within −0.5 and +0.1 points for
  the other window alone, +0.0 to +0.4 with the focused window's text too (the realistic
  case: screen context on), now within a budget, ranked, and with windows that have nothing
  to do with the text in the pool. Every model gains 17–21 points over the focused window's
  text alone.
- **Distractors don't hurt.** With three other documents' windows in the pool as windows
  viewed 2, 4 and 6 minutes ago, every model stays within 0.4 points (1.7B 61.3%): a recently viewed window needs words in
  common with the text, and the corpus's windows share few. The section changed 23 times in
  21 documents: each document's own window is in it from the start, so the two extra
  changes are distractor passages that began to match.
- **When the right window was only viewed earlier** (`--other-recent`: its window one
  minute old, with the three distractors), 1.7B saves 59.7%: its passages come in once the
  first matching words are typed, so the opening words miss them, and the section changed
  39 times (about twice per document: empty, then the matching window).
- **The 16 GB budget changes nothing here**: 2,048 tokens at n_ctx 4096 gives the same
  61.3% and the same 23 changes as 512 at 2048, because the selection is the same: each
  document's window (111–286 tokens) and the few distractor passages that match fit either
  budget; the rest score below the threshold.
- **Under a tight budget the ranking keeps most of the gain.** 1.7B, both, three
  distractors: 128 tokens (about one passage, a third to a half of a document's window)
  saves 53.5%, 256 tokens 59.5%, 512 tokens 61.3%, against 41.6% with no other window. The
  section changed 29, 25 and 23 times in 21 documents: with less room, a better passage
  displaces the first one more often as the text goes on.
- **The format hardly matters**: an `[End of other windows]` line after the section, the
  label `[Text in another window: …]`, or the screen section's own markers moved the 1.7B
  results by at most 0.3 points (other 59.0–59.3%, both 61.1–61.3%). The section keeps the
  shortest form, with the fewest markers to echo.
- **The token estimate** (`others::estimate_tokens`, which sizes the budget before the
  tokenizer is at hand), against the tokenizers on the corpus's 21 sections (`ft-replay
  --token-cost`): Qwen3 0.93 of the estimate in all, 1.05 at most for one section; Gemma 4
  0.95 and 1.02. A count of characters (3.5 a token) had been 0.97 in all but 1.56 for a
  sheet of figures, as Qwen3 spends a token per digit.
- First-suggestion latency rises with the larger first prefill (both: 201 → 212 ms p50 on
  1.7B; with distractors 261 ms, the passages they add); per-keystroke latency is unchanged.

In the app (`scripts/e2e-context.sh`, nothing typed, Qwen3-1.7B, dev build restricted to
TextEdit): with a ferry timetable open beside a draft about it, the first refresh read the
timetable through Accessibility in 62 ms, and the draft's first prompt carried it
(`other apps section: ~87 tokens (budget 2048): TextEdit — ctx-source.txt#0: "Ferry
timetable, Zanzibar crossing / …"`; 2,048 because this Mac has 18 GB). That run also showed
a busy app's window being marked as no longer on screen when a refresh couldn't read it in
time; such windows now stay visible with their text. Re-run after that fix (merge `670fd59`):
both refreshes read the timetable (25 and 13 ms) and kept it on screen, and the draft's
first suggestion prefilled only 13 tokens, since the new section had been prefilled in the
background when the pool arrived. With `FORETYPE_ONLY_APPS` naming no running app,
refreshes read 0 windows.

```bash
R=core/target/release/ft-replay; M="$HOME/Library/Application Support/Foretype/Models"
$R "$M/Qwen3-1.7B-Base.Q4_K_M.gguf" --corpus eval/corpus-multiwindow.jsonl --context-mode both
$R "$M/Qwen3-1.7B-Base.Q4_K_M.gguf" --corpus eval/corpus-multiwindow.jsonl --context-mode both --distractors 3 [--other-recent]
$R "$M/Qwen3-1.7B-Base.Q4_K_M.gguf" --corpus eval/corpus-multiwindow.jsonl --context-mode both --distractors 3 --other-tokens 128   # or 256, 512
$R "$M/Qwen3-1.7B-Base.Q4_K_M.gguf" --corpus eval/corpus-multiwindow.jsonl --context-mode both --distractors 3 --other-tokens 2048 --n-ctx 4096
$R "$M/Qwen3-1.7B-Base.Q4_K_M.gguf" --corpus eval/corpus-multiwindow.jsonl --token-cost
```

## WhatsApp Web in full-screen Chrome (2026-10-23)

Report: in WhatsApp Web the suggestion never showed after the caret, only in a card
(⇥ …) under the line at the text's left edge. Setup: the user's own Chrome (dev build
limited to its pid, Gemma 4 E2B Q4_K_M, installed Foretype quit), in native full screen on
a 1920×1080 display at 1× arranged above the built-in one (AX y −1080…0); the user typed an
unsent draft in "Message yourself" with pauses and deleted it. WhatsApp Web, like the
Claude app, gives no AX caret, so the pixel locator has to place the ghost text.

- Before (main `29a50d6`): 56 suggestions drawn as the mirror card, 1 inline; all 8 blink
  searches found nothing. The card was under the line because `GhostPanel` moved it below
  the field when its top was at y < 0, "above the screen"; on a display above the main
  one every y is negative.
- Diagnostic run (blink failure reasons logged): every capture returned nothing, for the
  field (1125×36 pt) and for the whole window (1920×992 pt). A probe outside Foretype: for
  that window `SCContentFilter(desktopIndependentWindow:)` fails with error -3811 ("Failed
  to start stream due to audio/video capture failure"); `SCContentFilter(display:including:)`
  with only that window captures the same rectangle.
- The chat-composer fixture with its window on the upper display (`WINDOW_POS`, not full
  screen, main build): 63 of 63 suggestions inline, so 1× and negative coordinates were
  not the problem.
- After (this fix, same setup): 33 of 33 suggestions inline, no card; the user saw the
  ghost text right after the caret. The first capture logged `only through its display
  (full screen)`; a blink found the caret when the field got focus (4 frames, 484 ms),
  before the first keystroke, and the first suggestion was drawn inline 0.2 s after it.
  3 blinks and 7 pause verifies in all, 1 solid search found no caret. Screen context
  (same capture) read 702 and 708 characters (704 and 374 ms).
- Self-tests: `--caret-selftest` (30 cases, worst error 0.00 pt) and `--font-selftest` pass.

## Cross-app context: performance (2026-10-23)

Phase D (`feat/context-perf`, D47): two prompts in the KV cache with the new header
prefilled in the background, saved contexts, q8_0 KV, cheaper OCR of other windows. *Before*
is `main` at `ef47c37` (0.1.5: one sequence, f16 KV, flash attention on by llama.cpp's own
choice), *after* this branch, both rerun here one after another, one `ft-replay` at a time
on the GPU, AC power. Flash attention was already on before Phase D: llama.cpp's default
(`auto`) turns it on with Metal (`resolve_fused_ops: Flash Attention enabled` in its log),
so Phase A's note that attention there was "quadratic without flash attention" was wrong;
the q8_0 cache is the only change on that front.

### q8_0 KV cache: keystrokes saved, latency, memory

`eval/corpus.jsonl` (53 documents, none) and `eval/corpus-multiwindow.jsonl` (21, both,
512-token section), n_ctx 2048, 4 words, greedy, prefetch, instant user.

| Model | Engine | corpus.jsonl: saved, model p50 / p90 | multi-window both: saved, model p50 / p90 |
|---|---|---:|---:|
| Qwen3-1.7B | before (f16, one sequence) | 41.9%, 81 / 111 ms | 61.1%, 87 / 146 ms |
| | after, f16, two slots | 41.9%, 79 / 109 ms | 61.1%, 84 / 132 ms |
| | after, q8_0, two slots (two runs) | 41.9%, 89 / 127 and 87 / 121 ms | 61.1%, 90 / 141 ms |
| Qwen3-0.6B | before | 39.9%, 51 / 79 ms | 58.8%, 54 / 90 ms |
| | after, q8_0 | 39.9%, 53 / 74 ms | 58.6%, 54 / 84 ms |

`--ctx-bench` (a prompt filled to 90% of the window; first suggestion from an empty cache,
then 40 keystrokes; this process's footprint, Activity Monitor's Memory):

| Model | n_ctx | KV, cells | First suggestion p50 | Prefill | Keystrokes p50 / p90 | Footprint loaded / peak |
|---|---:|---|---:|---:|---:|---:|
| Qwen3-1.7B | 2048 | f16, 2,048 (before) | 1,584 ms | 1,206 tok/s | 78 / 140 ms | 385 / 428 MB |
| | 2048 | q8_0, 2,048 | 1,636 ms | 1,172 tok/s | 76 / 147 ms | 283 / 327 MB |
| | 4096 | f16, 4,096 (before) | 3,365 ms | 1,118 tok/s | 89 / 163 ms | 613 / 659 MB |
| | 4096 | q8_0, 4,096 | 3,416 ms | 1,099 tok/s | 82 / 156 ms | 399 / 448 MB |
| | 4096 | q8_0, 8,192 (two slots) | 3,442 ms | 1,099 tok/s | 79 / 147 ms | 639 / 687 MB |
| Qwen3-0.6B | 2048 | f16, 2,048 (before) | 649 ms | 3,052 tok/s | 58 / 107 ms | 389 / 419 MB |
| | 2048 | q8_0, 2,048 | 640 ms | 3,057 tok/s | 48 / 89 ms | 282 / 313 MB |
| | 4096 | f16, 4,096 (before) | 1,500 ms | 2,527 tok/s | 64 / 114 ms | 613 / 647 MB |
| | 4096 | q8_0, 4,096 | 1,507 ms | 2,511 tok/s | 54 / 98 ms | 401 / 437 MB |

- **Keystrokes saved don't change** with q8_0 on either corpus (0.6B's multi-window 58.8 →
  58.6% is within the 0.3 points runs repeat to).
- **Memory halves as expected**: the KV cache drops from 112 to 60 KB per token on both
  models, so n_ctx 4096 in q8_0 costs what 2048 cost in f16 (1.7B 399 vs 385 MB, 0.6B 401
  vs 389 MB loaded): D42's next step for Macs under 16 GB holds.
- **Latency depends on the prompt's length.** Against a long cache q8_0 is no slower, even a
  little faster (1.7B at 4096: 82 vs 89 ms; 0.6B: 54 vs 64 ms): there is half as much KV to
  read. On the short prompts of `corpus.jsonl` it costs 1.7B 6–10 ms at p50 and 10–18 ms at
  p90 (two clean runs; a third that shared the GPU with another test gave 91 / 204 ms),
  0.6B 2 ms: dequantizing costs more than it saves when there is little to read. So the app
  uses q8_0 only while other apps' text is on (long prompts, where memory matters) and keeps
  f16 otherwise.
- Two slots with f16 (the app without other apps' text) type exactly as before (79 / 109
  vs 81 / 111 ms).

### Typing across a change of other apps' text (`ft-replay --switch-bench`)

Per document of the multi-window corpus: its own other window in the pool and its screen
text, the shell's warm-up at focus, 40 characters typed at a fixed pace of a key every 150 ms
(about 80 words a minute, whatever the suggestion's latency), then a long window opens beside
it (the pool changes, the shell warms the field) and 40 more characters are typed at the
same pace. Latency is the time from the key to the suggestion; the first suggestion after
the change is the first model call after it.

| Setup | Prompt after the change | Keys before p50 / p90 | First after the change p50 / p90 / max | While the new header prefills p50 / p90 | After p50 / p90 | New header ready p50 / p90 / max | Peak footprint |
|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen3-1.7B, 16 GB: before (f16, one sequence) | 1,964 tokens | 76 / 113 ms | **1,055 / 1,624 / 1,693 ms** | — | 98 / 160 ms | 880 / 1,574 ms (in the key's way) | 652 MB |
| Qwen3-1.7B, 16 GB: after (q8_0, two slots, 8,192 cells) | 1,964 tokens | 80 / 114 ms | **108 / 179 / 220 ms** | 122 / 220 ms (44 keys) | 102 / 167 ms | 3,109 / 4,448 / 6,406 ms (in the background) | 662 MB |
| Qwen3-0.6B, under 16 GB: before (f16, n_ctx 2048) | 523 tokens | 50 / 78 ms | 75 / 190 / 201 ms | — | 58 / 85 ms | 131 / 142 ms | 412 MB |
| Qwen3-0.6B, under 16 GB: after (q8_0, n_ctx 4096 in 4,096 cells) | 523 tokens | 53 / 83 ms | 66 / 85 / 109 ms | 47 ms (1 key) | 62 / 90 ms | 190 / 258 / 272 ms | 426 MB |

- **The first suggestion after a context change no longer waits for it**: on the default
  model with a full 2,048-token section, 1,055 → 108 ms at p50 and 1,624 → 179 ms at p90,
  served with the previous header (2 keystrokes per change at p50) while the new one
  prefills. On an 8 GB-style setup the section is smaller and the wait was short already;
  its p90 drops 190 → 85 ms.
- **Keystrokes typed while the new header prefills** take 122 / 220 ms (p50 / p90) against
  80 / 114 ms before the change: a keystroke can arrive during a background step and waits
  for it to finish (steps of about 40 ms while typing). Once it is ready, 102 / 167 ms: the
  prompt is now 2,000 tokens rather than 300, the same as the old engine's 98 / 160 ms.
- **The new header is ready in 3.1 s at p50, not 2 s,** with a full 2,048-token section and
  nonstop typing: suggestions keep the GPU busy about two thirds of the time at a key every
  150 ms, and 1,964 tokens need 1.8 s of GPU on their own at Qwen3-1.7B's 1,100 tokens/s.
  The old engine was ready in 0.9 s only because it made the next key wait for it. With
  a pause in typing it is done in about 2.1–2.4 s (*Background step length* below), and the
  corpus's real sections (111–286 tokens) are ready in under 0.3 s (0.6B: 190 ms for 523
  tokens).
- Memory with two slots, q8_0 and n_ctx 4096 on 16 GB: 662 MB peak against 652 MB for one
  f16 slot. Saved contexts come on top (below).

### Background step length (`ft-replay --chunk-bench`)

A prompt of 60% of a 4,096-token window (2,458 tokens on Qwen3-1.7B, q8_0) prefilled in the
background in steps of a given length, back to back (no typing), 8 documents:

| Step asked for | Ready p50 | Steps | A step p50 / p90 / max |
|---:|---:|---:|---:|
| 10 ms | 4,251 ms | 153 | 27 / 32 / 41 ms |
| 40 ms | 4,760 ms | 118 | 40 / 49 / 77 ms |
| 80 ms | 2,906 ms | 36 | 82 / 93 / 101 ms |
| 160 ms | 2,383 ms | 14 | 160 / 177 / 182 ms |
| 640 ms | 2,145 ms | 4 | 429 / 467 / 476 ms |

A decode costs about 15 ms before its first token (the weights are read once per batch), so
16-token steps run at half the speed of 500-token ones. 0.6B with 2,048 tokens: 1.9 s at 10
ms, 0.94 s at 40 ms, 0.73 s at 160 ms. The worker uses 40 ms steps while keys arrive (what
a keystroke may wait for) and 120 ms once the user has stopped for a second. Before the
steps were sized this way (a rate measured on small pieces kept the pieces small) the 40 ms
row took 5.3 s.

### Slots, background prefill and saved contexts give a fresh prefill's suggestions (`--check-cache`)

The reusing engine against one reset before every request (greedy, 4 words), as in
*Cache rollback* above. `--fields 3` interleaves three documents 15 requests at a time,
each with its own 1,400-character screen text, and prefills every request in the background
first, so the slots, shared prefixes, background steps and (with `--saved-mb`) saved
contexts are all exercised:

| Model, KV | Check | Requests | Identical |
|---|---|---:|---:|
| Qwen3-1.7B, f16, before (one sequence) | `--long`, 4 documents | 798 | 99.7% (from *Cache rollback*) |
| Qwen3-1.7B, f16, two slots | `--long`, 4 documents | 1,424 | 99.8% |
| Qwen3-0.6B, f16, one slot | `--fields 3`, 3 documents | 420 | 100% |
| Qwen3-0.6B, f16, two slots, saved contexts (3 saved, 225 MB) | `--fields 3` | 420 | 100% |
| Qwen3-1.7B, f16, two slots, saved contexts (3 saved, 228 MB) | `--fields 3`, 3 documents | 636 | 100% |
| Qwen3-1.7B, q8_0, two slots, saved contexts (5 saved, 199 MB) | `--fields 3`, 3 documents | 636 | 97.8% |

- These checks only hold with the GPU to themselves: when another model ran on it at the
  same time, generation hit the 300 ms deadline in some requests and not in others, and the
  same configurations read 83–92% (1.7B, 0.6B). The rows above ran alone.
- They found one bug, fixed before these runs: saving the slot about to be reused could drop
  the saved context that was about to be restored, and another one was restored in its
  place; the next decode failed (llama.cpp rejects a sequence with a gap in its positions),
  or, where positions happened to line up, the slot held another field's text. Gemma 4 E2B
  went from 72% to 96.5% identical with the fix (both runs shared the GPU).
- With q8_0 the reusing engine and fresh prefills agree on 97.8% (above) and 95.9% (the
  `--long` check, 1,424 requests, run while the Mac was building): q8_0 rounds the cache, so
  a single-token decode and a 512-token batch differ a little more than in f16. Keystrokes
  saved on both corpora don't change (first table).
- A saved context holds a whole prompt: about 75 MB for 650 tokens in f16 and 40 MB in
  q8_0 on Qwen3-1.7B, so the 384 MB from 16 GB keep 5 to 9 fields of that size.

### A 1,024-token section under 16 GB?

D42 allowed Macs under 16 GB a section of 1,024 tokens once q8_0 makes n_ctx 4096 cost
today's memory, if more passages help. The multi-window corpus with both contexts and three
distractor windows, n_ctx 4096 in 4,096 q8_0 cells (as the app runs there now):

| Model | 512 tokens | 1,024 tokens |
|---|---:|---:|
| Qwen3-0.6B | 58.5%, 23 section changes, first p50 124 ms | 58.5%, 23 changes, first p50 122 ms |
| Qwen3-1.7B | 61.2%, 23 changes, first p50 272 ms | 61.2%, 23 changes, first p50 266 ms |

Nothing changes: each document's other window (111–286 tokens) and the few distractor
passages that match fit 512 tokens already, as Phase C found for 2,048 at n_ctx 4096. The
budget stays 512 under 16 GB; a corpus with longer source windows would be needed to show
a gain.

### OCR of other windows (`Foretype --ocr-bench`)

A rendered document window (1,000×720 points, 16 lines of figures, dates and names) read
with Vision's fast level, as the pool reads windows without Accessibility text; median of 5
after a warm-up run, the capture itself not timed:

| Text | Pixels per point | Time | CPU | Words read |
|---|---:|---:|---:|---:|
| 13 pt | 2 (Retina) | 37 ms | 28 ms | 100% |
| | 1.5 | 41 ms | 25 ms | 95.5% |
| | 1 | 35 ms | 24 ms | 87.3% |
| 11 pt | 2 | 39 ms | 28 ms | 99.3% |
| | 1.5 | 47 ms | 26 ms | 95.5% |
| | 1 | 36 ms | 23 ms | 48.5% |

- **Downscaling buys nothing**: Vision's fast level takes the same time at any of these
  sizes (it scales internally) and reads fewer words, half of the 11 pt ones at one pixel
  per point. Captures keep their full resolution. The 64×64 hash costs 0.1–0.6 ms.
- What changed instead: at most 400 ms of OCR per refresh (no capture is started after
  that), and a refresh after a typing pause doesn't capture a window OCR'd less than a
  minute ago (a refresh on a window or app switch still does, and an unchanged picture is
  still not read again). Each refresh now logs its CPU time
  (`context: switch refresh, … OCR … ms, CPU … ms`).

## How to reproduce

See `docs/DEVELOPMENT.md` (ft-replay section). For release notes, run the full corpus with
the default model and record the summary line here.
