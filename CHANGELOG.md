# Changelog

No release has been tagged yet; the version in `core/Cargo.toml` is 0.1.0. Entries are by
roadmap phase.

## Unreleased

### Pixel caret locator (2026-10-20)
- **New:** ghost text at the caret in apps whose Accessibility API gives no caret geometry.
  When `CaretResolver` finds no caret (or an app's rule says `"caret": "pixel"`), Foretype
  captures the text field of the app's own window at typing pauses, finds the caret as the
  one thin bar that blinks (blink detector, ~0.7 s) or as a bar of the learned colour and
  height near the predicted position (verify, one capture ~45 ms), and between captures
  moves it by the rendered width of the typed text. Images are never kept. Needs Screen
  Recording and follows the Screen Context switch.
- **LibreOffice:** its paragraph frames are 98 pt above the text but its character rects are
  right, so the caret resolver rejected them. The pixel caret now confirms such rects (two
  matches) and the app's rects are used from then on, with no captures. Fonts are scaled to
  the zoom on screen when an app reports the unzoomed size (LibreOffice: 12 pt for a 29 pt
  line). Not yet usable end to end: after a programmatic open Writer reports no focused
  element (see `docs/MEASUREMENTS.md`).
- `compat/apps.json`: `caret` key (`pixel` | `ax`), `AppRule.caret` in the core;
  `FORETYPE_CARET` overrides it for testing.
- `Foretype --caret-selftest` (no permissions), `Foretype --caret-measure PID TITLE`,
  `scripts/caret-measure.sh` and `scripts/e2e-pixel-caret.sh` (caret moved through
  Accessibility, nothing typed); `ftdrive` gains `title`, `frame`, `caret`, `close`, `quit`.

### Fresh Chrome (2026-10-20)
- **Fix:** a Chrome process no other Accessibility client had primed could get no
  suggestions. Chrome turns on web content only 2 s after `AXEnhancedUserInterface` is set
  and cancels if it is cleared sooner, and it sometimes clears the flag itself as it
  activates. Foretype now checks the flag 0.5 s after setting it and while Chrome shows no
  focused element, sets it again only when it reads `false`, and never re-sets it while it
  is set (that restarts Chrome's wait). A fresh Chrome gets suggestions after 2–3 s.
- `FORETYPE_ONLY_APPS` accepts pids, and apps it excludes are no longer primed.
- `scripts/e2e-chrome-fresh.sh` (no typing) and `tools/spike/probe/run_chrome_triggers.sh`.

### macOS leftovers (2026-10-19/20)
- **Gemma 4 and Qwen3.5 run** in the built-in engine: a full-size sliding-window cache for
  Gemma 4, recurrent-state snapshots for Qwen3.5's hybrid layers, and a full re-prefill when
  a KV truncation fails. `ft-replay --check-cache` verifies cache reuse against a fresh
  context. Gemma 4 E2B (Q4_K_M) is in the model catalog as an opt-in quality model
  (42.8% keystrokes saved, p50 109 ms); Qwen3.5 0.8B measured worse than Qwen3 0.6B and
  is not offered.
- **Fix:** ad-hoc builds with Sparkle embedded crashed at launch (hardened runtime + library
  validation without a Team ID); the runtime now applies only to Developer ID builds.
- Sparkle update tested end to end with a local feed (`scripts/sparkle-local-test.sh`).
- Measurement tools: a sudo-free energy meter (`tools/energy`), `scripts/bench-mac.sh` for
  the base M1/M4 numbers, an unprimed-Chrome probe; `ftdrive` drives the app's menu and
  windows over Accessibility.
- Setup window, menu, Custom Instructions window, ghost-text placement and live screen
  capture checked by eye.
- Windows and Linux shells deferred: macOS only for now (D22).

### Documentation (2026-10-19)
- `CLAUDE.md`, `docs/` (architecture, decisions, development, measurements, roadmap),
  the Cotypist research report and notes, and the Phase 0 spike (`tools/spike/`) added to
  the repository.

### Fixes (2026-10-19)
- Link clang's runtime into the core's test binaries and `ft-replay` (`core/build.rs`):
  clean builds failed with `___isPlatformVersionAtLeast` undefined.
- CI workflow set to manual trigger only.
- Sparkle pinned to 2.10.0 in `mac/Package.swift`.

### Phase 4: packaging (2026-10-19)
- Model catalog (`models/catalog.json`) in the core, tier chosen by RAM; resumable,
  SHA-256-verified downloads; Model menu.
- First-run setup window (Accessibility, Screen Recording, model).
- Bring-your-own server: `llama-server` (grammar token healing) or OpenAI-compatible
  completions endpoints; API key in the Keychain; engine swapped without restarting capture.
- Release pipeline: Developer ID signing with timestamps, Sparkle 2 (opt-in build, signed
  inside-out), DMG, notarization and stapling when configured, appcast item, Homebrew cask
  template. CI and release workflows. MIT and Apache-2.0 license texts; evaluation corpus.

### Phase 3: quality and personalization (2026-10-19)
- Opt-in writing history (only fields with an accepted suggestion, typed text ≥ 20
  characters), ChaCha20-Poly1305 encrypted with a Keychain key; delete from the menu.
- Vocabulary bias at decode time and up to two same-app examples in the prompt header;
  strength Gentle / Balanced / Strong.
- Custom instructions for all apps and per app.
- Prefetch of the next suggestion on mains power.
- `ft-replay`: corpus mode, reaction time, leave-one-out personalization.

### Phase 2: compatibility breadth (2026-10-19)
- Terminals (Terminal, iTerm, WezTerm, Alacritty) suggest only on AI-agent prompt lines.
- Insertion strategies (keystrokes, paste, paste-long, first-word-then-paste) with
  clipboard restore when access is "always allow".
- Hotkeys: force suggestions on the current line; snooze an app for 5 minutes.
- Chromium font matching from measured text width.
- Idle model unload after 5 minutes; 80 ms mid-word debounce on battery.
- Compatibility DB grown to about 50 apps; Terminal e2e test.

### Phase 1: Mac MVP (2026-10-19)
- Rust core: policy gate, type-through/backspace/cache reuse, word-by-word accept, prompt
  builder with byte-stable header, in-process llama.cpp with prefix-cache reuse, rollback
  and token healing, C ABI, `ft-replay`.
- Swift shell: Accessibility capture thread, caret resolver (TextKit fix), ghost panel and
  mirror card, two event taps, Unicode keystroke insertion, menu-bar app, TextEdit e2e test.
- Screen context: ScreenCaptureKit + Vision OCR near the field, refreshed on focus and
  typing pauses.

### Phase 0: research and spikes (2026-10-18/19)
- Research report on how Cotypist works and the open-source landscape.
- Accessibility probe across 10 apps, llama.cpp benchmarks, replay evaluation harness.
