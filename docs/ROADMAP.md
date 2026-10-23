# Roadmap

The phases come from the research report (`docs/research/cotypist-report.md`, "Six phases
from Mac MVP to Linux"), adjusted as the work went.

| Phase | Status | Where |
|---|---|---|
| 0. Spikes and evaluation harness | Done; GPU energy and the unprimed-Chrome baseline measured 2026-10-20; base M1/M4 need those Macs (`scripts/bench-mac.sh`) | `tools/spike/`, `phase0/measurements` |
| 1. Mac MVP | Done | `0bf074c`, branch history on `main` |
| 2. Compatibility breadth | Done | `phase2/compat-breadth` |
| 3. Quality and personalization | Done; Gemma 4 and Qwen3.5 run since KV snapshots (beam search, emoji, autocorrect deferred) | `phase3/personalization`, `phase3/kv-snapshots` |
| 4. Packaging (1.0 groundwork) | Done; Sparkle update verified with a local feed (2026-10-20); notarization needs a Developer ID | `phase4/packaging`, `phase4/sparkle-test` |
| 5. Windows shell | Deferred: macOS only for now (D22) | |
| 6. Linux shell | Deferred: macOS only for now (D22) | |

Since Phase 4: the pixel caret locator (D31, `feat/pixel-caret`); pause and power-aware
pausing (D39, `feat/pause`); a waiting update shown in the menu and Settings (D40).

## Cross-app context (planned 2026-10-23)

Suggestions that use what is open in other apps (a Word document, slides or a web page
beside the email being written) and on every display, without slowing typing down. The
user's decisions are D42: opt-in with its own setting, recently viewed windows kept 10
minutes in memory only, password managers never read by default, off for server backends;
8 GB Macs get it with a small budget (Accessibility text only, a 512-token section, n_ctx
2048).

| Phase | Status | What |
|---|---|---|
| A. Baseline and multi-monitor audit | Done (`feat/context-baseline`) | `eval/corpus-multiwindow.jsonl` (21 items) and `ft-replay --context-mode`, `--n-ctx`, `--ctx-bench`; keystrokes saved with no, focused-window and other-app context, first-suggestion latency, prefill and memory at n_ctx 2048/4096/8192 for every catalog model (`docs/MEASUREMENTS.md`); multi-monitor coordinate fixes with `--geometry-selftest`; the FORETYPE_ONLY_APPS hook point for reading (`docs/ARCHITECTURE.md`) |
| B. Context collector | Next | Text of other apps' windows on every display: Accessibility text first (no Screen Recording needed, exact), OCR of the window as the fallback; a recently-viewed pool (10 minutes, memory only, cleared on pause, lock and sleep); the never-read list (password managers), per-app opt-out, FORETYPE_ONLY_APPS, secure input; off for server backends; its own setting. On Macs under 12 GB, Accessibility text only: no OCR of other windows (D42) |
| C. Relevance and prompt | Planned | Rank the pool's passages against the text being written (BM25, in the core), a prompt section of its own (labelled by app and window, after the focused window's text, before the body) within a token budget (D42: 512 tokens at n_ctx 2048 on Macs under 12 GB; provisionally 2,048 at n_ctx 4096 on 16 GB and up, to tune on the corpus), counted in tokens and trimmed first when a prompt would overflow, and `ft_engine_set_context` so the shell sends context separately from each keystroke's snapshot; measure on the multi-window corpus |
| D. Performance | Planned | Keep a bigger header off the typing path: prefill a changed context on a second KV sequence in the background and switch when ready (double buffering); cache KV states per context (`llama_state_seq_*`); q8_0 KV cache and flash attention (memory and long-context decode; with q8_0, n_ctx 4096 on an 8 GB Mac costs today's KV memory, and its section may grow to 1,024 tokens if Phase C shows it helps); cheaper OCR (`.fast` level, only changed regions, fewer refreshes); re-run `scripts/bench-context.sh` against the Phase A numbers |
| E. UX and docs | Planned | The setting, the never-read list and a "what Foretype sees" view in Settings; onboarding text; README, REFERENCE and privacy notes; what 8 GB Macs get (no OCR of other windows, a smaller budget) explained in Settings |

What Phase A found (details in `docs/MEASUREMENTS.md`, "Cross-app context baseline"):
- The other app's text is worth it: +17 to +20 points of keystrokes saved on every model
  (Qwen3-1.7B 41.6% → 60.9%) on a corpus written to quote it, a best case.
- A long context is slow to start: with a full window the first suggestion after a change
  takes 1.5 s (2,048 tokens) to 7.6 s (8,192) on Qwen3-1.7B, 0.6–20 s across the models. The
  context section needs a token budget and background prefill (Phase D) before it can grow
  past today's size; keystrokes against a full 8,192-token cache are 30–70% slower on Qwen3
  (Gemma 4 E2B: no change).
- Memory: +0.22 GB at n_ctx 4096 and +0.67 GB at 8192 for Qwen3-0.6B and 1.7B (the 8 GB
  models), half that with a q8_0 KV cache.
- The engine's 300 ms generation deadline started before llama.cpp had finished the last
  prefill batch, so a long cold prefill cut the first suggestion short (Qwen3-1.7B, 1,835
  tokens: 15 of 21 stopped after one word). Fixed: the engine waits for the GPU at the end
  of the prefill; none are cut, in about the same time.
- Multi-monitor: on the developer's Mac the second display is above the built-in one, where
  screen context used the wrong capture scale and cards went below fields, and a window
  moved there after focus had another window of the same app captured instead; fixed and
  checked on that display (ghost text, pixel caret, mirror card, capture scale).
- With noise in the screen section the model echoed a header marker (`[End of screen t…`):
  Phase C should keep section markers out of suggestions.
- Windows on other Spaces aren't on screen, so ScreenCaptureKit's on-screen list (and
  Accessibility, for most apps) can't see them: the pool has to keep what was read while
  they were visible.

## What each phase delivered

- **Phase 1**: Rust core (policy gate, session reuse, prompt builder, in-process llama.cpp
  with prefix-cache reuse and token healing, C ABI) and the Swift shell (Accessibility
  capture on its own thread, caret resolver, ghost panel, two-tap key handling, Unicode
  keystroke insertion, menu-bar app). Screen context (ScreenCaptureKit + Vision OCR) was
  added at the user's request.
- **Phase 2**: terminals suggest only on AI-agent prompts; per-app insertion strategies
  with paste and clipboard restore; force and snooze hotkeys; Chromium font matching by
  width; idle model unload and battery debounce; compatibility DB of about 50 apps;
  Terminal e2e test.
- **Phase 3**: opt-in encrypted writing history, vocabulary bias and same-app examples;
  custom instructions (global and per app); prefetch on mains power; corpus and
  leave-one-out modes in `ft-replay`.
- **Phase 4**: model catalog with pinned checksums and a resumable, verified downloader;
  setup window; bring-your-own server backends; Developer ID signing, Sparkle 2 (opt-in
  build), DMG, notarization and stapling, appcast item and Homebrew cask; CI (manual) and
  release workflows; license texts.

## Deferred: Windows and Linux

The user wants Foretype on macOS only for now (`docs/DECISIONS.md` D22). The plans below
are kept for if that changes; the core stays portable.

### Phase 5: Windows

- Rust shell crate using `windows-rs` and `uiautomation`: focused element, caret via UI
  Automation `TextPattern2::GetCaretRange`, text before and after the caret.
- Low-level keyboard hook (WH_KEYBOARD_LL) for Tab, the accept-all key and Esc, active only
  while a suggestion shows; `SendInput` with Unicode for insertion.
- Layered, topmost, click-through window for the ghost text; DPI awareness.
- llama.cpp with CPU, CUDA and Vulkan builds. Model catalog shared.
- Later: a TSF text service (in-host DLL plus engine process) for native preedit ghost text.
- Exit: works in Notepad, Word, Outlook, Chrome, Edge and Teams.

### Phase 6: Linux

- Fcitx5 addon (C++) linking the core: preedit ghost text, deterministic acceptance; then an
  IBus engine. AT-SPI (`atspi` crate) for surrounding text where available. Wayland first.
- Exit: packaged for two distributions; works in GTK, Qt and Chromium fields under Wayland.

## Backlog (any phase)

- **Models**: a purpose-tuned small completion model (deferred by the user on 2026-10-20: it
  needs a better training set than oasst1 to be worth GPU hours). (KV snapshots for Gemma 4
  and Qwen3.5 landed in `phase3/kv-snapshots`; MLX was measured and isn't faster, D32.)
- **Quality**: a model trained for fill-in-the-middle, so mid-line can use the rest of the
  line (Qwen3's FIM tokens don't work on prose). (Beam search, the typo gate, emoji,
  autocorrect and mid-line landed in `feat/quality`.)
- **Compatibility**: app-by-app insertion testing to fill `insertion` overrides; the chat
  labels of Cursor and Windsurf (VS Code's "Message input" is checked); text-marker reads in
  a real WebKit editor (Chrome's textarea answers none); the overlay checked by eye in
  Safari, Mail and Notes; the pixel caret locator checked in
  Teams and Obsidian/CodeMirror (not tested: Teams is the developer's live chat, Obsidian
  is not installed) and with a non-blinking caret; LibreOffice Writer end to end (it
  reported no `AXFocusedUIElement` for a document opened from outside; a fallback could
  take the paragraph `AXTextArea` whose selection is valid). (Chat inputs, Google Docs and
  Arc/Dia hints, text markers and the pixel caret locator landed.)
- **Personalization**: per-app retrieval tuning (needs a larger personal corpus than the 12
  self-written documents: tuning on those would fit noise). Cotypist's history can't be
  imported (encrypted, D30); Import Writing… takes text files instead. (The llama-server
  `logit_bias` landed and was measured: 40.7% → 41.0–41.3%.) About You: cue phrases in
  other languages (English only), several identities picked per app, a signature block
  after the name (job title, company), phone numbers matched ignoring spaces and the
  country code. (One set of details with exact fills and a writer line landed.)
- **Product**: more languages (English and Hindi so far). (Settings window, statistics,
  model manager polish, downloads that resume after a relaunch, adding an app from the
  Settings window, the Apple on-device fallback and localization landed.)
- **Measurement**: base M1 and M4 benchmarks (`scripts/bench-mac.sh` on those Macs), CPU and
  DRAM energy (`sudo powermetrics`; GPU energy is measured), the release-day corpus
  numbers.
- **Release** (D36): the pipeline is built and tested locally: self-signed "Foretype"
  identity, EdDSA update key, feed on the latest release, tag-triggered workflow,
  `scripts/release.sh`, `install.sh`, silent update on idle. Left: the signing backup and
  update key as repository secrets, the repository made public, the first workflow run
  (v0.1.0), a clean-account install test and a v0.1.1 update test. Later, optionally: a
  Developer ID with notarization (one re-grant for everyone), and a Homebrew tap.

## Known limitations

- Insertion overrides exist but every app still defaults to keystrokes.
- Checked by eye on 2026-10-20: ghost-text placement in TextEdit and in a Chrome textarea
  (the fixture page), the setup window, the menu, the Custom Instructions window, live
  screen capture (development build), the Settings window's tabs (five then, eight since
  2026-10-23, each fitting a 13-inch MacBook Air) with model delete,
  app remove, statistics reset and download pause/resume. Not yet: the overlay in Safari,
  Mail and Notes, the bundled app's own Screen Recording grant, Cmd-, and the editing keys
  in Foretype's windows (they need real keystrokes).
- A Chrome process that no Accessibility client has primed shows its web fields 2–3 s
  after Foretype first sees it in front: Chrome waits 2 s after `AXEnhancedUserInterface`
  is set before it turns on web content (`docs/MEASUREMENTS.md`). Foretype keeps the flag
  set until it quits, which some window managers dislike.
- Pixel caret (apps without caret geometry): the first field of an app after launch shows
  the mirror card until its caret first blinks off (about 0.7 s; on focus, so usually before
  the first keystroke); later fields, new lines and wraps are found while typing with one
  capture (D37). A caret that never blinks is never found; between checks the ghost follows
  a font guess (about 1 pt off over a line without the host font). Measured in TextEdit
  against its AX caret, in a Chrome chat-composer fixture, in the Claude app and in WhatsApp
  Web in full-screen Chrome on a display above the main one (`docs/MEASUREMENTS.md`).
- About You fills only at the end of a line, from English cue phrases, and only when what
  was typed is the start of the stored value exactly as written (case aside).
- OpenAI-compatible servers save about half as much typing as llama-server or the built-in
  engine (no token healing).
- Ad-hoc builds lose the Accessibility and Screen Recording grants on every rebuild. Releases
  and local builds signed with the "Foretype" identity keep them (D35, D36).
- Releases aren't notarized: a DMG downloaded in a browser needs Open Anyway once (the
  one-line installer doesn't).
