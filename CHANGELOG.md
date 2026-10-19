# Changelog

No release has been tagged yet; the version in `core/Cargo.toml` is 0.1.0. Entries are by
roadmap phase.

## Unreleased

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
