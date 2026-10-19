# Phase 0 results

Measured on 2026-10-18 on a MacBook Pro (Mac15,6). The machine has an Apple M3 Pro (5P + 6E CPU, 14-core GPU) and 18 GB of RAM, runs macOS 27.0.1 (26A434), and was on AC power. Raw data is in `results/`. How to re-run is in [README.md](README.md).

Two other on-device AI apps were running but idle during the benchmarks: Cotypist (with its `gemma-4-E2B-Q4_C.gguf`) and the Ollama 0.35.1 app. Neither was generating, but both may hold GPU memory. Several other apps hold Accessibility on this Mac (Cotypist, Raycast, Codex Computer Use, Claude, AnyDesk, Teams), and that affected the Chrome results in section 2.

**Headline:** neither Phase 0 risk blocks the blueprint on this machine.
- Warm-cache inference answers a keystroke in 16 ms (p50) on the default 1.7B model.
- Accessibility reports every keystroke in 5–9 ms (p50) in TextEdit, Safari and Chrome.
- In a simulated replay with an ideal Tab-pressing user, the models saved 39–44% of keystrokes. Every keystroke prefilled only about one new token.
- The surprises are in the details:
  - a system-wide AX call that always fails on macOS 27, even from a signed app bundle;
  - a caret rect that is one line off in every TextKit app tested;
  - a marked range that TextKit apps always report;
  - unusable caret geometry in Teams, LibreOffice and VS Code;
  - TCC signing traps.

  All are listed below.

## 1. Inference: warm-cache latency is not the bottleneck

llama.cpp 0.7.0 (Homebrew, build 11669, commit 620d2225c), Metal, all layers on the GPU, flash attention `auto`, f16 KV cache. Models are the blueprint's tiers, taken from mradermacher's GGUFs and sha256-verified (`bench/models.tsv`).

### Throughput (llama-bench, 5 reps, cold context)

| Model | File size | pp512 tok/s | tg128 tok/s |
|---|---:|---:|---:|
| Qwen3-0.6B-Base Q8_0 | 0.64 GB | 3,647 ± 10 | 136.7 ± 5.2 |
| Qwen3-1.7B-Base Q4_K_M | 1.11 GB | 1,264 ± 3 | 89.2 ± 2.6 |
| Qwen3-4B-Base Q4_K_M | 2.50 GB | 480 ± 30 | 44.3 ± 1.4 |

### Few-token prefill on a warm cache (llama-bench `-d`, model-side time to first token)

Each figure is the time to prefill k new tokens with d tokens already in the KV cache. The logits of the last prefilled token produce the first suggested token, so this is the model's share of the time to first token.

| Model | pp1 @ d512 | pp4 @ d512 | pp8 @ d512 | pp4 @ d2048 | 8 decode steps @ d512 | @ d2048 |
|---|---:|---:|---:|---:|---:|---:|
| 0.6B Q8_0 | 7.3 ms | 8.0 ms | 10.9 ms | 11.4 ms | 56.5 ms | 66.3 ms |
| 1.7B Q4_K_M | 10.9 ms | 14.7 ms | 15.8 ms | 16.3 ms | 85.8 ms | 99.9 ms |
| 4B Q4_K_M | 23.0 ms | 32.1 ms | 34.5 ms | 34.4 ms | 179.3 ms | 191.6 ms |

### Simulated keystroke loop (end to end through llama-server)

The harness is `bench/keystroke_loop.py`. It ran llama-server with one slot and `cache_prompt`. Setup: a byte-stable header plus 2,000 characters of email prose (412 tokens) were prefilled with a zero-token request. The harness then typed the next 60 characters one at a time at a 150 ms cadence. Each keystroke resent the full text and asked for 8 greedy tokens. TTFT is client-measured, from sending the request to the first streamed token, so it includes HTTP, tokenization and the longest-common-prefix (LCP) check.

| Model | Tokens prefilled per keystroke, p50 (max) | TTFT p50 | TTFT p90 | TTFT max | 8-token suggestion p50 | p90 | Decode ms/token |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0.6B Q8_0 | 1 (2) | 12.2 ms | 16.5 ms | 24.7 ms | 68.2 ms | 72.1 ms | 8.0 |
| 1.7B Q4_K_M | 1 (2) | 15.7 ms | 20.6 ms | 23.5 ms | 97.2 ms | 103.0 ms | 11.6 |
| 4B Q4_K_M | 1 (2) | 24.7 ms | 32.7 ms | 39.6 ms | 186.1 ms | 209.2 ms | 23.0 |

Cold costs, off the keystroke path:

| Model | Server load | Cold prefill of the 412-token field |
|---|---:|---:|
| 0.6B | 1.0 s | 293 ms |
| 1.7B | 1.0 s | 444 ms |
| 4B | 2.0 s | 833 ms |

The cold-prefill figure is the first request after load, so it includes Metal warm-up.

### What this says

- **Prefix reuse works on dense Qwen3 without custom code.** When text is typed one character at a time, the retokenized last word costs only 1–2 tokens of prefill. The server reused 411 of 412 cached tokens on each request. This confirms the blueprint's single cache path: truncate to the common prefix, then prefill the delta.
- **Time to first token is far inside budget.** The target is p50 ≤ 120 ms and p90 ≤ 300 ms. The default 1.7B reached p50 16 ms and p90 21 ms, and even the 4B model reached p90 33 ms. Most of the remaining latency budget belongs to AX capture and rendering, not the model.
- **Decode length decides the tier.** A full 8-token suggestion took 97 ms at p50 on 1.7B and 186–209 ms on 4B. The blueprint caps a suggestion at roughly 250 ms. The 4B model fits only at short lengths, or if words are streamed into the overlay as they arrive. That supports 1.7B as the default and 4B as an opt-in for 16 GB+ machines.
- **Cold prefill must stay off the critical path.** A 412-token field costs 0.3–0.8 s cold. This confirms the zero-token warm-up on focus change.
- **Base M1 and M4 were not measured.** The roadmap's exit criterion asks for numbers on those chips, and only this M3 Pro was available. Decode is memory-bandwidth bound: 150 GB/s here against 68 GB/s on a base M1. My unmeasured estimate is about 2.2× slower decode on a base M1, which puts a 1.7B 8-token suggestion near 210 ms there. Running `bench/run_bench.sh` on those machines is the remaining step.

## 2. Accessibility probe

`probe/run_apps.sh` ran six scenarios on 2026-10-19 with `bin/axprobe` (CDHash `4acbb824…`), launched as its own TCC-responsible process. Each scenario:

1. Opens a fixture: `fixtures/sample.txt` in TextEdit, or `fixtures/testpage.html` (textarea, or `#ce` for a contenteditable div) in Safari or Chrome.
2. Takes one snapshot.
3. Watches for 9 s while the probe types " we should keep going. Next week" (32 characters plus Cmd+Down, 120 ms apart) as Unicode `CGEvent`s.
4. Times 30 back-to-back snapshots.

The `-ax` scenarios add `--chromium-ax`. Raw JSONL is in `results/probe/` and the tables below come from `probe/analyze.py`.

#### Field as first seen (`--once`)

| Scenario | App | Role (description) | Value len | Selection | Marked range | Zero-length caret | Prev-char edge | Disagree px | AXFont |
|---|---|---|---:|---|---|---|---|---:|---|
| textedit | com.apple.TextEdit | AXTextArea (text entry area) | 166 | 0+0 | 166+0 | y=121 h=13 w=0 ⚠ outsideElementFrame | –  | – | Family=Menlo, Name=Menlo-Regular, Size=11, VisibleName=Menlo Regular |
| safari | com.apple.Safari | AXTextField (text field) | 210 | 0+210 | none | y=35 h=16 w=0 ⚠ outsideElementFrame | –  | – | Family=.AppleSystemUIFont, Name=.AppleSystemUIFont, Size=13, VisibleName=System Font Regular |
| safari-ce | com.apple.Safari | AXTextArea (text entry area) | 112 | 112+0 | none | y=190 h=20 w=2  | y=190  | 2 | Family=Georgia, Name=Georgia, Size=17 |
| chrome | com.google.Chrome | AXTextArea (text entry area) | 112 | 112+0 | none | y=96 h=20 w=0  | y=96  | 0 | Size=17 |
| chrome-ax | com.google.Chrome | AXTextArea (text entry area) | 112 | 112+0 | none | y=96 h=20 w=0  | y=96  | 0 | Size=17 |
| chrome-ce-ax | com.google.Chrome | AXTextArea (text entry area) | 112 | 112+0 | none | y=96 h=20 w=0  | y=96  | 0 | Size=17 |

#### Typing run (`--type`, 32 synthetic keystrokes at 120 ms)

| Scenario | Keys seen by tap | Tap lag p50 | Snapshots (notif / poll-only) | AX notifications per keystroke | Keystroke → AX notification p50 / p90 / max | Snapshot AX cost p50 / p90 | Zero-length rect vs prev-char edge |
|---|---:|---:|---|---|---|---|---|
| textedit (AXTextArea) | 33 | 0.31 ms | 32 / 2 | SelectedText 1.1, Value 1.0 | 5.2 / 8.8 / 14.3 ms | 2.9 / 7.8 ms | differ by 13 px; zero-length rejected 1/34 |
| safari (AXTextField/?/AXTextArea) | 33 | 0.35 ms | 34 / 2 | SelectedText 1.4, Value 3.0 | 4.8 / 28.7 / 92.2 ms | 6.0 / 9.8 ms | differ by 2 px; zero-length rejected 27/36 |
| safari-ce (AXTextArea) | 33 | 0.30 ms | 33 / 0 | SelectedText 3.1, Value 3.0 | 5.6 / 8.8 / 15.4 ms | 2.8 / 4.4 ms | differ by 2 px |
| chrome (AXTextArea) | 33 | 0.31 ms | 33 / 0 | SelectedText 2.0, Value 2.0 | 8.7 / 11.5 / 13.5 ms | 2.4 / 4.2 ms | differ by 0 px |
| chrome-ax (AXTextArea) | 33 | 0.37 ms | 34 / 1 | SelectedText 2.0, Value 2.0 | 7.8 / 10.1 / 13.5 ms | 2.9 / 4.2 ms | differ by 0 px; zero-length rejected 2/35 |
| chrome-ce-ax (AXTextArea) | 33 | 0.36 ms | 32 / 1 | SelectedText 2.0, Value 2.0 | 8.7 / 11.3 / 12.6 ms | 2.8 / 4.1 ms | differ by 0 px |

#### Back-to-back snapshot cost (`--bench 30`, ms p50 / p90)

| Scenario | App measured | Whole snapshot | AXFocusedUIElement | AXValue | AXSelectedTextRange | AXBoundsForRange(caret,0) | AXBoundsForRange(prev,1) | AXAttributedStringForRange(1) |
|---|---|---|---|---|---|---|---|---|
| textedit | com.apple.TextEdit | 4.4 / 5.8 (max 8.5) | 0.26 / 0.35 | 0.08 / 0.12 | 0.10 / 0.13 | 0.28 / 0.40 | 0.23 / 0.33 | 0.23 / 0.34 |
| safari | com.apple.Safari | 7.0 / 9.5 (max 19.4) | 0.52 / 0.63 | 0.08 / 0.12 | 0.08 / 0.12 | 0.32 / 0.37 | 0.36 / 0.44 | 3.25 / 3.88 |
| safari-ce | com.apple.Safari | 7.4 / 10.6 (max 20.9) | 0.51 / 0.67 | 0.08 / 0.10 | 0.08 / 0.10 | 0.38 / 0.51 | 0.48 / 0.72 | 3.78 / 4.11 |
| chrome | com.google.Chrome | 4.4 / 7.0 (max 15.7) | 0.30 / 0.48 | 0.09 / 0.13 | 0.17 / 0.27 | 0.12 / 0.19 | 0.16 / 0.20 | 0.77 / 0.97 |
| chrome-ax | com.anthropic.claudefordesktop | 2.4 / 5.1 (max 7.0) | 0.23 / 0.33 | 0.03 / 0.04 | 0.05 / 0.07 | 0.03 / 0.05 | – | 0.16 / 0.21 |
| chrome-ce-ax | com.google.Chrome | 3.3 / 6.0 (max 11.2) | 0.23 / 0.39 | 0.07 / 0.11 | 0.16 / 0.27 | 0.10 / 0.16 | 0.11 / 0.24 | 0.59 / 0.96 |

### What this says

**Change detection is fast and reliable for these three apps.**
- AX notifications reported all 32 keystrokes in every field.
- The 200 ms poll caught only 0–2 changes per run, all at app or focus switches.
- Keystroke to AX notification was p50 5–9 ms and p90 9–12 ms.
- A full snapshot cost p50 2–6 ms on top of that, so the blueprint's "keystroke → field snapshot ≤ 20 ms typical, 80 ms ceiling" holds for TextEdit, the Safari textarea and Chrome.
- One field broke the ceiling: Safari's address bar reached p90 29 ms and max 92 ms.
- Notification volume differs per app: TextEdit sends 1 selection + 1 value notification per keystroke, Chrome 2 + 2, and a Safari textarea 3 + 3. Coalesce them by revision; don't snapshot once per notification.

**macOS 27.0.1: system-wide `AXFocusedApplication` always fails.**
- It returned `kAXErrorCannotComplete` in about 5 µs on every call (about 400 recorded calls, zero successes), with no IPC attempted, even though the process was trusted.
- Per-app AX on the same process worked: observers registered, `AXFocusedUIElement` answered in 0.2–0.5 ms.
- The probe now falls back to `NSWorkspace.frontmostApplication`, which costs 0.2–0.3 ms, and then calls `AXUIElementCreateApplication(pid)`. `focusSource` in each snapshot records which path answered.
- A signed app bundle hits the same failure (section 5), both when launched by LaunchServices and when exec'd, and system-wide `AXFocusedUIElement` fails too. Only a Developer ID-signed build is untested. The capture layer must not rely on the system-wide element; Tabber's `AXFocusedUIElement`-from-system-wide path does not work on this Mac.

**The zero-length caret rect is one line too high in TextKit fields, and not only after a newline.**
- In TextEdit, `AXBoundsForRange(caret, 0)` reported y = line − 13 px at every position. This was visible at document start (y=121 against a frame top of 134) and at every character on the new last line, where the previous-character edge put the caret at y=160 and the zero-length rect said 147.
- Safari's address bar (`AXTextField`) has the same problem: 16 px, one line.
- The validator caught it only when the rect fell outside the element frame, so for TextEdit it chose the wrong strategy 33 times out of 34.
- Chrome's two strategies agreed exactly. The Safari textarea returned a 2 px-wide caret 2 px left of the previous-character edge, which is consistent rather than a failure.
- Implication for the caret resolver: always compute both rects. When they differ by about one line height, trust the previous-character edge. At a line start (previous character is a newline), apply a per-app line offset learned from earlier agreement, and cache the winning strategy per app as the blueprint proposes.

**TextEdit always reports a marked range.**
- `AXTextInputMarkedRange` came back as a zero-length range at the caret (166+0 … 198+0) with no IME composition.
- Safari and Chrome return `noValue`.
- The "suppress while marked text exists" guard must test `length > 0`. Otherwise it silently disables completion in every TextKit field.

**Fonts.**
- TextEdit and Safari return the full `AXFont` dictionary (family, name, size, visible name).
- Chrome returns only `AXFontSize`, as Tabber found, so the width-matching font resolver is needed for Chromium.
- Safari's `AXAttributedStringForRange` is the most expensive call measured: 3.3–3.8 ms p50, against 0.6–0.8 ms in Chrome and 0.2 ms in TextEdit. Read fonts once per field, not per keystroke.

**Chromium priming could not be tested cleanly.**
- Chrome's `AXEnhancedUserInterface` was already `true` before the probe touched it, presumably set by one of the other Accessibility clients running.
- Writing it returned `notImplemented`, and `AXManualAccessibility` returned `attributeUnsupported` on Chrome (it is Electron-only).
- The 100 ms read-back never saw Chrome clear the flag.
- So the "empty bounds and font until primed" failure was not reproduced in Chrome. Chrome geometry was correct in all three Chrome scenarios, but only because the flag was already on. Microsoft Edge started unprimed and did reproduce it (section 4).
- In the `chrome-ax` run, Claude.app (Electron) briefly took focus. The probe set `AXManualAccessibility` on it (`ok`) and reset it to `false` on exit.

**Permissions on macOS 27.0.1.**
- Accessibility alone was enough. `CGPreflightListenEventAccess` and `CGPreflightPostEventAccess` both turned true without an Input Monitoring grant, and the listen-only session tap saw every keystroke with a p50 lag of 0.3 ms.
- This answers the blueprint's open question for this OS version. Secure Event Input was never active during the runs.

**TCC traps that will bite contributors.**
1. Under Claude Code (and any parent that doesn't disclaim), TCC attributes a CLI to its parent. The probe had to be launched through Claude's `disclaimer` helper to own its grant.
2. SwiftPM's linker-signed ad-hoc binaries (`flags=adhoc,linker-signed`) can never be granted. tccd logs "Failed to match existing code requirement" even with the toggle on. A full `codesign --sign -` fixes this (`probe/make_bin.sh`).
3. A grant is tied to the cdhash. After a rebuild, switching the toggle off and on does not help. The row must be removed with − and re-added.

This strengthens the blueprint's advice to sign even development builds with a stable identity.

### Caveats

- Keystrokes were synthetic (Unicode payload, virtual key 0, posted at the HID tap, 120 ms apart). Human typing and IME composition were not tested.
- In the `safari` scenario, Safari kept its address bar focused after `open`, so most of that run typed into the URL field. Nothing was submitted. Its rows describe Safari's address bar, with the textarea appearing only in the last 7 snapshots.
- The `chrome-ax` bench measured Claude's composer, because Claude had taken focus. Chrome's bench numbers come from `chrome` and `chrome-ce-ax`.
- The `#ce` (contenteditable) variants report the same role and description as the textarea in both browsers. AX data alone doesn't prove the contenteditable variant was the one focused.
- The `tapDisabled (userInput)` line at the end of three watch logs is the probe disabling its own tap on exit. It was fixed in source after these runs; the granted `bin/axprobe` predates the fix.
- Only 3 apps were covered. Phase 0 calls for about 15.

## 3. Replay evaluation

The harness is `eval/replay_eval.py`; `eval/run_eval.sh` runs all three models and `eval/summarize_eval.py` builds the table. Raw JSON is in `results/eval/`. It replays each document one keystroke at a time against a llama-server `/completion` backend (`cache_prompt`, one slot, greedy). `--backend URL` points it at any engine that speaks the same API, including the Phase 1 engine. Each keystroke goes through these steps:

1. **Gate.** No request is made mid-word unless the fragment can still become a dictionary word. The dictionary is `/usr/share/dict` web2 plus proper names, with inflection rules and a short list of modern words. A second rule blocks requests with more than 8 characters after the caret, but it never fires in an append-only replay.
2. **Token healing.** The partial word, with its leading whitespace, is backed off the prompt. A GBNF grammar then forces the continuation to begin with exactly that fragment.
3. **Display.** The suggestion is the text beyond the fragment, cut to the preset length (2, 4 or 7 words).
4. **Simulated user.** The user presses Tab to accept the next word whenever it exactly matches what they type next. Otherwise they type one character. A character that matches the ghost text advances it without a new request.

One request generating 16 tokens serves all three presets, because greedy decoding makes the shorter suggestions prefixes of the longer one. Latency for an N-word preset is the time the N-th word was complete in the stream.

**Corpus** (`eval/corpus/corpus.jsonl`): 53 documents, 2,367 words, 12,704 characters.
- 12 documents (1,056 words) are written for this eval in email, chat, notes, essay, support and review registers.
- 41 are English human-written messages from OpenAssistant/oasst1 (1,311 words, Apache-2.0). They come from the first 600 validation rows, about 1 MB, downloaded with the user's approval. `eval/corpus/build_corpus.py` documents the filter.

| Model | Preset (words) | Keystrokes saved | Chars per accept (net of Tab) | Acceptance rate | Requests | Suggestion latency p50 / p90 | TTFT p50 / p90 | Tokens per accepted char |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Qwen3-0.6B-Base.Q8_0 | 2 | 39.3% | 3.65 (2.65) | 37.9% | 3724 | 38 / 72 ms | 16 / 20 ms | 2.34 |
| Qwen3-0.6B-Base.Q8_0 | 4 | 39.3% | 3.65 (2.65) | 38.2% | 3312 | 58 / 95 ms | 16 / 21 ms | 3.22 |
| Qwen3-0.6B-Base.Q8_0 | 7 | 39.3% | 3.65 (2.65) | 38.3% | 3257 | 84 / 126 ms | 16 / 21 ms | 4.76 |
| Qwen3-1.7B-Base.Q4_K_M | 2 | 41.6% | 3.76 (2.76) | 40.6% | 3459 | 53 / 91 ms | 20 / 24 ms | 2.05 |
| Qwen3-1.7B-Base.Q4_K_M | 4 | 41.7% | 3.76 (2.76) | 41.1% | 3015 | 81 / 123 ms | 20 / 24 ms | 2.78 |
| Qwen3-1.7B-Base.Q4_K_M | 7 | 41.7% | 3.76 (2.76) | 41.0% | 2943 | 119 / 170 ms | 20 / 24 ms | 4.13 |
| Qwen3-4B-Base.Q4_K_M | 2 | 44.1% | 3.87 (2.87) | 41.7% | 3365 | 102 / 159 ms | 31 / 38 ms | 1.89 |
| Qwen3-4B-Base.Q4_K_M | 4 | 44.2% | 3.87 (2.87) | 41.9% | 2890 | 150 / 226 ms | 31 / 38 ms | 2.52 |
| Qwen3-4B-Base.Q4_K_M | 7 | 44.2% | 3.87 (2.87) | 41.6% | 2818 | 230 / 321 ms | 31 / 38 ms | 3.77 |

### What this says

- **Savings scale modestly with size.** Keystrokes saved went 39.3% → 41.7% → 44.2% (0.6B → 1.7B → 4B), and characters per accepted word went 3.65 → 3.76 → 3.87. Most accepts complete a word after 1–3 typed characters, so token healing is doing the heavy lifting. Across about 10,000 requests the grammar-constrained continuation never failed to match the typed fragment.
- **The length preset changes cost, not savings, under this user model.** Words are accepted one Tab at a time and decoding is greedy, so 2-, 4- and 7-word suggestions save the same keystrokes. Longer presets only cut the request count, by 12–16%.
  - On 1.7B, latency rose from 53 to 81 to 119 ms at p50 for 2, 4 and 7 words.
  - Tokens generated per accepted character rose from 2.05 to 2.78 to 4.13.
  - On 4B, the 7-word preset's p90 of 321 ms breaks the 250 ms cap.
  - Default to 2–4 words, and stream longer suggestions.
- **Energy was not measured.** `powermetrics` needs sudo. The proxy, generated tokens per accepted character, is 1.9–4.8 depending on model and preset. Short presets on the larger model are the most token-efficient, at 1.89 on 4B with 2 words.
- **The dictionary gate costs little but blocks real words.** It blocked 0.6–1.2% of gate decisions. In a typo-free corpus every block is a false block: names (Priya), British spelling (colours), brands (ChatGPT, Roblox), acronyms (BBC, PC) and foreign words (hôpital). The gate needs locale variants, the user's own vocabulary (contacts, history) and leniency for capitalized words.
- **Not comparable to TabType's figures.** TabType reports 1.46 against 1.17 characters saved per accept. Its corpus, user model and possibly its definition differ, so these numbers are not comparable.

**Caveats.**
- The simulated user is ideal: they never miss a correct suggestion and never accept a wrong one. These are upper bounds for this policy.
- The replay never edits mid-line and has no IME input.
- Latencies were measured with back-to-back requests on the M3 Pro, partly while the app probes in section 4 ran, with Cotypist idle in the background.
- Part of the corpus was written by me and may be more predictable than real mail.

## 4. More apps

Each app got a new blank document or draft, opened through its menus with computer use (full-screen control only for Teams). The probe typed the 32-character phrase into that document alone. `--type-only-in` stops typing if any other app is frontmost, checked before every key.

Apps not run:
- **Mail and Messages:** not approved by the user.
- **Pages, Word, Slack, Obsidian, Notion and WhatsApp:** not installed.

VS Code ran read-only: computer use grants it click-only access, so it was not typed into.

#### Field as first seen (`--once`)

| Scenario | App | Role (description) | Value len | Selection | Marked range | Zero-length caret | Prev-char edge | Disagree px | AXFont |
|---|---|---|---:|---|---|---|---|---:|---|
| edge | com.microsoft.edgemac | None (None) | None | None+None | none | –  | –  | – | none |
| edge-ax | com.microsoft.edgemac | None (None) | None | None+None | none | –  | –  | – | none |
| notes | com.apple.Notes | AXTextArea (text entry area) | None | 0+0 | 0+0 | y=94 h=23 w=0  | –  | – | none |
| stickies | com.apple.Stickies | AXTextArea (text entry area) | 0 | 0+0 | 0+0 | y=319 h=14 w=0  | –  | – | none |
| libreoffice-writer | org.libreoffice.script | AXTextArea (text entry area) | 0 | 0+0 | none | y=-2147483178 h=-2147483647 w=-2147483647 ⚠ tooTall,outsideElementFrame,offScreen | –  | – | none |
| wordcraft | ai.storyteller.wordcraft | AXGroup (group) | 1 | 0+0 | none | y=321.035 h=21.959 w=0  | –  | – | none |
| teams | com.microsoft.teams2 | AXTextArea (text entry area) | 23 | 21+0 | none | y=982 h=0 w=0 ⚠ zeroHeight,outsideElementFrame | y=982 ⚠ zeroHeight,outsideElementFrame | – | Size=14 |
| vscode | com.microsoft.VSCode | AXTextArea (editor) | 0 | 0+0 | none | y=982 h=0 w=0 ⚠ zeroHeight | –  | – | none |

#### Typing run (`--type`, 32 synthetic keystrokes at 120 ms)

| Scenario | Keys seen by tap | Tap lag p50 | Snapshots (notif / poll-only) | AX notifications per keystroke | Keystroke → AX notification p50 / p90 / max | Snapshot AX cost p50 / p90 | Zero-length rect vs prev-char edge |
|---|---:|---:|---|---|---|---|---|
| edge (?) | 33 | 0.25 ms | 1 / 0 |  | – / – / – ms | 0.1 / 0.1 ms | agree |
| edge-ax (?/AXTextArea) | 33 | 0.28 ms | 33 / 0 | SelectedText 2.0, Value 2.0 | 4.5 / 10.8 / 17.1 ms | 1.0 / 2.5 ms | differ by 0 px |
| notes (AXTextArea) | 33 | 0.34 ms | 32 / 0 | SelectedText 2.1, Value 1.9 | 7.3 / 10.6 / 138.4 ms | 10.2 / 37.7 ms | differ by 23 px |
| stickies (AXTextArea) | 33 | 0.30 ms | 33 / 0 | SelectedText 1.1, Value 1.1 | 3.4 / 6.7 / 18.9 ms | 2.0 / 3.0 ms | differ by 14 px |
| libreoffice-writer (AXTextArea) | 33 | 0.33 ms | 34 / 0 | SelectedText 1.0, Value 1.0 | 32.4 / 39.7 / 42.0 ms | 4.7 / 13.3 ms | agree; zero-length rejected 34/34 |
| wordcraft (AXGroup) | 33 | 0.28 ms | 21 / 8 | SelectedText 1.0, Value 1.0 | 56.8 / 106.7 / 113.2 ms | 122.6 / 136.5 ms | differ by 0 px |
| teams (AXTextArea) | 33 | 0.31 ms | 33 / 0 | SelectedText 2.0, Value 2.0 | 12.3 / 43.0 / 70.5 ms | 2.1 / 3.7 ms | agree; zero-length rejected 33/33 |

#### Back-to-back snapshot cost (`--bench 30`, ms p50 / p90)

| Scenario | App measured | Whole snapshot | AXFocusedUIElement | AXValue | AXSelectedTextRange | AXBoundsForRange(caret,0) | AXBoundsForRange(prev,1) | AXAttributedStringForRange(1) |
|---|---|---|---|---|---|---|---|---|
| edge | com.microsoft.edgemac | 0.6 / 0.8 (max 8.0) | 0.17 / 0.22 | – | – | – | – | – |
| edge-ax | com.microsoft.edgemac | 0.5 / 0.7 (max 0.8) | 0.17 / 0.20 | – | – | – | – | – |
| notes | com.apple.Notes | 5.4 / 6.3 (max 18.4) | 0.20 / 0.32 | 0.71 / 0.87 | 0.09 / 0.12 | 0.25 / 0.37 | 0.28 / 0.37 | 0.54 / 0.63 |
| stickies | com.apple.Stickies | 4.4 / 5.1 (max 10.5) | 0.17 / 0.22 | 0.05 / 0.09 | 0.06 / 0.10 | 0.17 / 0.33 | 0.25 / 0.37 | 0.25 / 0.36 |
| libreoffice-writer | org.libreoffice.script | 3.9 / 5.3 (max 11.4) | 0.22 / 0.30 | 0.06 / 0.10 | 0.07 / 0.13 | 0.11 / 0.16 | 0.27 / 0.39 | 0.75 / 1.01 |
| wordcraft | ai.storyteller.wordcraft | 4.0 / 5.6 (max 84.3) | 0.18 / 0.25 | 0.06 / 0.11 | 0.06 / 0.10 | 0.06 / 0.10 | 0.13 / 0.16 | 0.09 / 0.18 |
| teams | com.microsoft.teams2 | 3.7 / 4.8 (max 21.3) | 0.56 / 0.66 | 0.09 / 0.11 | 0.96 / 1.22 | 0.08 / 0.11 | 0.11 / 0.18 | 0.49 / 0.68 |
| vscode | com.microsoft.VSCode | 1.7 / 4.4 (max 10.3) | 0.24 / 0.34 | 0.06 / 0.07 | 0.08 / 0.11 | 0.07 / 0.10 | – | – |

### What this says

- **The TextKit caret bug is systemic.**
  - Notes (23 px) and Stickies (14 px) show the same "zero-length rect one line too high" as TextEdit, at every position.
  - Both also report a zero-length marked range at the caret.
  - The validator accepted the wrong rect in every snapshot where both rects could be measured: 31 in Notes and 32 in Stickies. The remaining snapshot in each had no previous character.
  - For TextKit apps, prefer the previous-character edge, and fall back to "zero-length rect plus one line height" only at line starts.
- **LibreOffice Writer has unusable geometry.**
  - The zero-length rect is a sentinel value (about −2³¹).
  - The element frame covers a single 24 px line, while character rects sit about 100 px lower. A save dialog showed the same roughly 110 px AX offset.
  - Notifications work, but keystroke → notification is slow (p50 32 ms), and `AXValue` occasionally took up to 31 ms (median 0.07 ms).
  - LibreOffice needs the pixel caret fallback.
- **WordCraft is accurate but slow while typing.**
  - It is a WebKit-based Word-style editor that exposes the page as an `AXGroup`.
  - Both caret strategies agree. AX calls, however, took 26–28 ms each during typing (`AXSize`, `AXPosition`, `AXSelectedTextRange`), against 0.1 ms when idle. A snapshot took 123 ms at p50 and keystroke → notification 57 / 107 ms.
  - 8 changes were caught only by the poll, and there is no `AXFont`.
  - Batch reads with `AXUIElementCopyMultipleAttributeValues` and cache the frame.
- **The Teams new-chat compose box has no caret geometry.**
  - Notifications are fine: 2 + 2 per keystroke, p50 12 ms, p90 43 ms.
  - Both strategies return a zero-height rect at (0, 982), and the font gives size only.
  - Teams needs the pixel or text-marker fallback.
- **Edge reproduces the Chromium problem.**
  - With `AXEnhancedUserInterface=false`, `AXFocusedUIElement` returned `noValue`, and 32 typed keystrokes produced no notifications at all.
  - Setting the flag returned `notImplemented` but took effect, and the read-back showed `true`. Trust the read-back, not the error.
  - The tree appeared only after the next keystroke; a 0.5 s wait alone was not enough.
  - Primed, Edge behaved like Chrome: 2 + 2 notifications per keystroke, p50 4.5 ms, strategies agree, font size only.
- **VS Code exposes nothing.** The editor is an `AXTextArea` ("editor") with value length 0 and a zero-height caret. Monaco exposes no text or geometry without VS Code's screen-reader mode, which was not tested. Its flags were `AXEnhancedUserInterface=true` and `AXManualAccessibility=false`. A primed run was attempted, but Teams had come to the front and was captured instead. Typing was off for that run, and its files were deleted. That incident is why the `--type-only-in` guard exists.

**Cleanup.**
- **Notes:** the test note was moved to Recently Deleted.
- **Stickies:** the test note was discarded.
- **Writer:** the document was closed without saving.
- **WordCraft:** quit; its document was never saved.
- **Teams:** the new-chat text was cleared and the chat abandoned. Nothing was sent.
- **VS Code:** the temp file's tab was closed and the file deleted.
- **Left open:** the local test-page tabs in Safari, Chrome and Edge, and TextEdit's copy of `sample.txt`, which lives in a temp folder.

## 5. Signed-bundle focus check

`probe/make_app.sh` wraps `axprobe` in `bundle/AXProbe.app`:
- bundle ID `dev.phase0.AXProbe`;
- `LSUIElement`;
- a full ad-hoc signature with Info.plist bound.

The user granted it Accessibility, and it was trusted both when launched with `open -g`, a proper LaunchServices launch with launchd as parent, and when exec'd directly.

| Launch | System-wide `AXFocusedApplication` | System-wide `AXFocusedUIElement` | Per-app path (NSWorkspace pid → app element) |
|---|---|---|---|
| `open -g AXProbe.app --args --bench 30` | `cannotComplete` 30/30 | `cannotComplete` 30/30 | works; snapshot p50 6.3 ms |
| exec `AXProbe.app/Contents/MacOS/axprobe --bench 30` | `cannotComplete` 30/30 | `cannotComplete` 30/30 | works; snapshot p50 10.3 ms |

So on this Mac running macOS 27.0.1, the system-wide failure is not an artifact of an unbundled binary. Claude happened to be frontmost during this check, which doesn't affect the system-wide calls.

Still untested:
- a Developer ID-signed, notarized build (no Developer ID identity is available here);
- other Macs on 27.0.x, to rule out something specific to this one, which runs many Accessibility clients.

## 6. Not done

- **Base M1 and M4 numbers.** Only this M3 Pro was available. Run `bench/run_bench.sh` and `eval/run_eval.sh` on those machines.
- **An unprimed Chrome baseline.** It needs Cotypist and the other Accessibility clients quit and Chrome relaunched. Edge provides an unprimed Chromium data point in the meantime.
- **Remaining apps.**
  - Mail and Messages were not approved.
  - Pages, Word, Slack, Obsidian, Notion and WhatsApp are not installed.
  - VS Code typing was not possible with a click-only grant, and its screen-reader mode was not tested.
  - Human typing and IME were not tested anywhere.
- **Energy measurement.** `powermetrics` needs sudo, so only a proxy (tokens per accepted character) is reported.
- **System-wide focus from a Developer ID-signed, notarized build.**
- **Screen-recording context.** The user wants it as a core feature (ScreenCaptureKit + OCR). It was outside these spikes and has been flagged to the Phase 1 session.
