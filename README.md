# Foretype

Free, open-source, on-device inline autocomplete for every app: gray "ghost text" after
your caret, Tab to take the next word, the key above Tab to take all of it. A Cotypist-style
tool built so the engine can be shared across macOS, Windows and Linux.

Status: **Phase 1 MVP, macOS only.** Works end to end with a local Qwen3 base model in
every app except those off by default (terminals, code editors, password managers, remote
desktops); not packaged or notarized yet.

## How it works

```
 macOS shell (Swift)                                 core (Rust, C ABI)
 ──────────────────                                  ─────────────────
 FocusTracker  AX thread: observers + post-keystroke ─┐
               re-read burst + 0.5 s poll             │ snapshot JSON
 ScreenContext window capture + Vision OCR ───────────┤ (+ on-screen text near the field)
                                                      ▼
                                              policy gate ── per-app rules (compat/apps.json)
                                              session ────── type-through, cache, word accept
                                              context ────── byte-stable header + text before caret
                                              engine ─────── llama.cpp, prefix-cache reuse,
                                                             token healing, cancel per keystroke
                                                      │ suggestion state (never pixels)
 GhostPanel    non-activating click-through panel ◄───┘
 KeyTap        listen-only tap + consuming tap (only while a suggestion shows)
 Inserter      Unicode CGEvents, ≤20 UTF-16 units, annotated session tap
```

- `core/`: the portable engine (`foretype-core`). Prompt building, the policy gate,
  suggestion reuse and in-process llama.cpp inference on its own thread. It emits suggestion
  *state*, so a Windows TSF service or a Linux Fcitx5/IBus preedit can render the same
  output. C header: `core/include/foretype_core.h`.
- `mac/`: the macOS shell (SwiftPM, AppKit, Accessibility, event taps).
- `compat/apps.json`: per-app rules (off by default in terminals, code editors, password
  managers and remote desktops; Chromium/Electron accessibility priming). Licensed CC0 so
  any project can use it.

### Screen context

Like Cotypist, Foretype can read the text visible around the field you are typing in, such as
the chat you are answering or the email thread above your reply. ScreenCaptureKit captures the
focused window, on-device Vision OCR reads it, the field's own text is dropped, and the rows
nearest the field (up to about 1,400 characters) go into the prompt header. The image is thrown
away right after recognition and the text is only kept in memory.

- It needs the Screen Recording permission (asked once by `Foretype.app`; toggle under **Use
  Screen Context** in the menu). Without the permission everything else still works.
- Capture is skipped for secure fields, secure input, and apps where suggestions are off.
- It refreshes when a new field gets focus and after a 1.5 s typing pause at most every 15 s,
  never per keystroke, because new screen text changes the prompt header and costs a full
  prefill. The new header is prefilled in the background as soon as OCR finishes.
- Warm OCR takes 145–360 ms (M3 Pro), off the typing path. The very first run on a Mac takes
  much longer while Vision compiles its models.

On a chat-reply sample (`scripts/fixtures/chat-*.txt`), screen context raised keystrokes saved
from 29% to 66% and characters per Tab from 3.2 to 5.2, at the same latency. The reply was
written to refer to the visible messages, so treat this as a best case.

### Latency design

- The prompt ends *before* the partial word. Token healing masks the first decode steps to
  tokens consistent with what you typed, so the cached prefix is identical for a whole word
  and each keystroke prefills 0–2 tokens.
- Generated tokens are rolled back out of the KV cache after every suggestion.
- No fixed debounce: each keystroke cancels the in-flight job between decode steps.
- Typing through a visible suggestion, backspacing inside it, and repeated Tabs reuse it
  with no inference at all.

Measured with `ft-replay` on an M3 Pro (Qwen3-1.7B-Base Q4_K_M, sample email):
41–44% of keystrokes saved, 3.5–3.7 characters per Tab, model suggestions p50 74–85 ms and
p90 106–119 ms, 1 token prefilled per keystroke (p50).

## Build

Requirements: Apple Silicon, macOS 14+, Xcode command-line tools, Rust (`brew install rust cmake`).

```bash
scripts/build-mac.sh
```

This builds `core` (with Metal), the Swift shell, and `build/Foretype.app` (ad-hoc signed
unless `FORETYPE_SIGN_IDENTITY` is set).

## Run

Put a GGUF base model in `~/Library/Application Support/Foretype/Models/` (default tier:
`Qwen3-1.7B-Base.Q4_K_M.gguf`), or set `FORETYPE_MODEL=/path/to/model.gguf`. Open
`build/Foretype.app` and grant Accessibility when asked. The menu-bar icon has the on/off
switch, the suggestion length and a per-app toggle.

| Key | Action |
|---|---|
| Tab | insert the next word |
| key above Tab (` or §) | insert the whole suggestion |
| Esc | dismiss (no new suggestion until you type) |
| Option+Tab | a real Tab |

## Development

- `cargo test` in `core/` runs the unit tests (word splitting, prompt stability, session
  reuse, policy).
- `ft-replay MODEL TEXT_FILE` replays typing through the core and reports keystrokes saved,
  characters per accept and latency, with no UI.
- `scripts/e2e-textedit.sh` drives a new TextEdit document with synthetic keystrokes.
  It restricts Foretype to TextEdit (`FORETYPE_ONLY_APPS`), waits for the user to be idle,
  and aborts if focus leaves TextEdit.
- `FORETYPE_DEBUG=1` logs snapshots, caret strategy, suggestions and latency to stderr.
- `FORETYPE_ONLY_APPS=bundle.id,...` restricts reading and suggestions to those apps. Use
  it whenever you run a dev build on a machine you are also working on.
- `Foretype --ocr-selftest` renders a fake chat window and checks OCR and row assembly
  (no permissions needed). `ft-replay ... --screen FILE` adds screen text to a replay.
- **Accessibility grants and ad-hoc signing:** macOS ties the grant to the exact build, so
  every rebuild of an ad-hoc-signed `Foretype.app` needs the Accessibility entry removed
  and re-added. Sign with a stable identity (`FORETYPE_SIGN_IDENTITY`) to avoid that. A
  bare `mac/.build/release/Foretype` started from a terminal uses the terminal's own grant.

## Known limitations (MVP)

- Dense full-attention models only (Qwen3 base). Gemma 4 and Qwen3.5 need KV state
  snapshots (sliding-window / recurrent layers can't roll back).
- Keystroke insertion only; the per-app paste strategy and clipboard restore are not wired
  up yet.
- Chrome reports a font size but no font name, so ghost text there uses the system font.
- Screen context has only been tested through the OCR self-test and replays; live window
  capture needs the Screen Recording grant on `Foretype.app`, which the dev test setup
  doesn't have.
- No model download UI, personalization, autocorrect or emoji yet.
- Not notarized; no Sparkle updates yet.

## Licensing

Core and shell: MIT OR Apache-2.0. `compat/apps.json`: CC0-1.0. Default models (Qwen3
base) are Apache-2.0 and are not bundled.
