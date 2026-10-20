# Foretype: guidance for Claude

Foretype is a free, open-source, on-device inline autocomplete for every macOS app, in the
style of Cotypist: gray "ghost text" after the caret, **Tab** takes the next word, the key
above Tab takes all of it. A portable **Rust core** (`core/`) does everything except
platform plumbing; a **Swift macOS shell** (`mac/`) captures the focused field, draws the
overlay and types accepted text. The product is macOS only for now (user decision, 2026-10-19):
Windows and Linux shells are deferred, but the core stays portable so they remain possible.

Private GitHub repo: `DaraSingh1998/foretype`. Phases 1–4 of the roadmap are done (see
`docs/ROADMAP.md`).

## Read first

| Doc | What it holds |
|---|---|
| `README.md` | User-facing overview, install, features, measured numbers |
| `docs/ARCHITECTURE.md` | Components, threads, data flow, FFI contract and JSON shapes, prompt format, KV-cache and token-healing design |
| `docs/DECISIONS.md` | Why things are the way they are (ADR log): read before changing a design choice |
| `docs/DEVELOPMENT.md` | Build, test, replay, e2e tests, debugging, macOS permission (TCC) traps, how to add an app rule or a model |
| `docs/MEASUREMENTS.md` | Every benchmark and replay number so far, with conditions and how to reproduce |
| `docs/ROADMAP.md` | Phase status, known limitations, next work |
| `RELEASING.md` | Signing, notarization, Sparkle, DMG, Homebrew cask |
| `docs/research/` | The Cotypist research report and notes; Phase 0 spike results are in `tools/spike/RESULTS.md` |

## Commands

```bash
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo test --release --manifest-path core/Cargo.toml        # 25+ unit tests, no model needed
scripts/build-mac.sh                                          # core + Swift shell + build/Foretype.app (ad-hoc signed)
mac/.build/release/Foretype --font-selftest                   # no permissions needed
mac/.build/release/Foretype --ocr-selftest                    # no permissions needed
cargo build --release --bins --manifest-path core/Cargo.toml  # ft-replay
core/target/release/ft-replay "$HOME/Library/Application Support/Foretype/Models/Qwen3-1.7B-Base.Q4_K_M.gguf" --corpus eval/corpus.jsonl
```

The first `cargo build` compiles llama.cpp with Metal (about a minute). Models are not in
the repo (`.gitignore` excludes `*.gguf`); the three catalog models are installed in
`~/Library/Application Support/Foretype/Models` on the developer's Mac. **Ask before
downloading any model** (name, size, source).

## Rules for working on this repo

- **Branch per phase or feature** (`phase3/kv-snapshots`, `fix/...`, `docs/...`). Merge into
  `main` and push only when the user says so. Use the user's configured git identity and
  the commit attribution line the system provides.
- **CI is manual-only on purpose** (`workflow_dispatch`): macOS runner minutes are billed at
  10× on this private repo. Don't add push or pull_request triggers unless asked.
- **Keep the core portable.** No AppKit, Accessibility or Mac-only APIs in `core/`. The core
  emits suggestion *state*, never pixels.
- **When the FFI changes**, update all three: `core/src/ffi.rs`, `core/include/foretype_core.h`
  and `mac/Sources/Foretype/Engine.swift`.
- **Measure before claiming quality changes**: run `ft-replay` on `eval/corpus.jsonl` before
  and after, and record the result in `docs/MEASUREMENTS.md`.
- Keep `README.md`, `docs/` and `CHANGELOG.md` current when behaviour changes.

## Testing on the user's Mac: safety rules (learned the hard way)

- **Never run a dev build without `FORETYPE_ONLY_APPS=<bundle id>`** while the user may be
  working. An early unrestricted run read and showed suggestions in the user's Microsoft
  Teams for about 5 seconds (nothing was inserted). To test an app the user also has open
  (Chrome), start a separate process and pass its pid instead (`scripts/e2e-chrome-fresh.sh`).
- The e2e scripts (`scripts/e2e-textedit.sh`, `scripts/e2e-terminal.sh`) type synthetic
  keystrokes. They restrict the app, wait for the user to be idle and pause if focus leaves,
  but **tell the user before running them** and ask them to stay off the keyboard.
- **Cotypist is installed** and also intercepts Tab. Ask before quitting it for a test, and
  remind the user to reopen it afterwards.
- Never type into existing conversations or documents; only into new, unsent drafts the
  test created, and close or discard them afterwards. Never press Return or Send in
  messaging apps.
- AppleScript control of Terminal triggers a consent prompt; the terminal test opens a
  `.command` window running `tee` instead.

## macOS gotchas (see docs/DEVELOPMENT.md)

- A bare `mac/.build/release/Foretype` started from a terminal **inherits that terminal's
  Accessibility grant** (the responsible process). A bundled, ad-hoc-signed
  `build/Foretype.app` is its own identity and needs its Accessibility entry removed and
  re-added after every rebuild. There is no stable signing identity on this Mac yet.
- On macOS 27, system-wide `AXFocusedApplication` always fails; use the frontmost pid.
- TextKit fields report the zero-length caret rect one line too high; TextEdit reports a
  zero-length marked range at all times; Chrome reports a font size but no name.
- Reading the general pasteboard can raise a permission alert (macOS 15.4+); paste
  insertion runs only when access is "always allow".

## Environment variables

| Variable | Effect |
|---|---|
| `FORETYPE_MODEL` | GGUF to load (dev; skips the setup window when also trusted) |
| `FORETYPE_ONLY_APPS` | Comma-separated bundle IDs or pids; nothing else is read, primed or intercepted |
| `FORETYPE_DEBUG` | Logs snapshots, caret strategy, suggestions, latency to stderr |
| `FORETYPE_INSERTION` | Forces `keystrokes`, `paste`, `paste-long` or `first-word-then-paste` |
| `FORETYPE_MODELS_DIR`, `FORETYPE_MODEL_BASE_URL` | Model folder and download host (tests) |
| `FORETYPE_LLAMA_LOGS` | Keep llama.cpp's own logging |
| `FORETYPE_TEXT_MARKERS` | `1` reads web fields through text markers even when ranges work (testing) |
| Build: `FORETYPE_SIGN_IDENTITY`, `FORETYPE_SPARKLE`, `FORETYPE_FEED_URL`, `FORETYPE_SPARKLE_PUBLIC_KEY`, `FORETYPE_NOTARY_PROFILE`, `FORETYPE_VERSION`, `SPARKLE_BIN` | See `RELEASING.md` |
