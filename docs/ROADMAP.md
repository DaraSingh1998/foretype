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

- **Models**: a purpose-tuned small completion model; MLX as an experiment. (KV snapshots
  for Gemma 4 and Qwen3.5 landed in `phase3/kv-snapshots`.)
- **Quality**: phrase beam search (Cotypist reportedly uses a 9-wide beam), a dictionary gate
  that knows the user's vocabulary and names (the spike's gate falsely blocked names,
  British spellings, brands), emoji shortcodes, inline autocorrect, mid-line completion.
- **Compatibility**: pixel caret locator for apps without geometry (Teams, LibreOffice,
  Obsidian/CodeMirror); WebKit/Chromium text-marker reads; app-by-app insertion testing to
  fill `insertion` overrides; VS Code/Cursor chat panels; Google Docs (needs its
  screen-reader mode); Arc/Dia "Text Metrics" guidance in the UI; the overlay checked by eye
  in Safari, Mail and Notes.
- **Personalization**: Cotypist history import; per-app retrieval tuning; logit bias for
  `llama-server` via its `logit_bias` parameter.
- **Product**: Foundation Models fallback (zero download), localization, a preferences
  window, statistics (words saved), model manager polish (delete models, disk usage).
- **Measurement**: base M1 and M4 benchmarks (`scripts/bench-mac.sh` on those Macs), CPU and
  DRAM energy (`sudo powermetrics`; GPU energy is measured), the release-day corpus
  numbers.
- **Release**: Developer ID certificate, notarization run, Sparkle keys and appcast on
  GitHub Pages, Homebrew tap, first tagged release.

## Known limitations

- Insertion overrides exist but every app still defaults to keystrokes.
- Checked by eye on 2026-10-20: ghost-text placement in TextEdit and in a Chrome textarea
  (the fixture page), the setup window, the menu, the Custom Instructions window, live
  screen capture (development build). Not yet: the overlay in Safari, Mail and Notes, the
  bundled app's own Screen Recording grant.
- A Chrome process that no Accessibility client has primed shows its web fields 2–3 s
  after Foretype first sees it in front: Chrome waits 2 s after `AXEnhancedUserInterface`
  is set before it turns on web content (`docs/MEASUREMENTS.md`). Foretype keeps the flag
  set until it quits, which some window managers dislike.
- OpenAI-compatible servers save about half as much typing as llama-server or the built-in
  engine (no token healing).
- Ad-hoc builds lose the Accessibility grant on every update until releases are signed
  with a Developer ID.
