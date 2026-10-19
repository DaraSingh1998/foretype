# Foretype

Free, open-source, on-device inline autocomplete for every app: gray "ghost text" after
your caret, Tab to take the next word, the key above Tab to take all of it. A Cotypist-style
tool built so the engine can be shared across macOS, Windows and Linux.

Status: **Phase 4 (packaging), macOS only.** Works end to end with a local Qwen3 base
model in every app except those off by default (code editors, password managers, remote
desktops, spreadsheets). In Terminal and iTerm it suggests only on AI-agent prompts (Claude
Code, Codex, ...). Not packaged or notarized yet.

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
- `compat/apps.json`: per-app rules for about 50 apps: off by default (code editors,
  password managers, remote desktops, spreadsheets), agent-prompt-only (terminals),
  insertion strategy, Chromium/Electron accessibility priming. Licensed CC0 so any project
  can use it.

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

### Personalization (opt-in)

**Learn From My Writing** (menu: Personalization) is off by default. When on:

- **What is recorded:** only fields where you accepted a suggestion, only the text you typed
  there (not text that was already in the field), only when it is at least 20 characters.
  A field is recorded when focus leaves it or when its text is cleared (a sent chat
  message). Secure fields, and apps where suggestions are off, are never recorded.
- **Where:** `~/Library/Application Support/Foretype/history.bin`, each record sealed with
  ChaCha20-Poly1305. The 256-bit key lives in your login Keychain and is only created or
  read when personalization is on. Nothing leaves the Mac. **Delete Writing History…**
  deletes the file, and suggestions are unbiased again immediately.
- **How it is used:** no fine-tuning. Words you use often (at least twice, ignoring very
  common English words) get a small logit boost: whole-word tokens at a word start, and
  completions towards your words once you have typed their first letters. Up to two short
  snippets of your earlier writing in the same app go into the prompt header, picked once
  per field so the cache stays warm. Strength: Gentle, Balanced (default), Strong.

Measured leave-one-out on the 12 self-written documents of the Phase 0 corpus (each one
replayed with the other 11 as history; Qwen3-1.7B): keystrokes saved went from 41.0% to
41.6% (Gentle and Balanced), 41.3% (Strong), and 41.2% with the vocabulary bias alone, so
the earlier-writing examples contribute most of the gain. Those documents share few names
and phrases; real histories repeat more, so treat this as a floor.

### Custom instructions

**Custom Instructions…** in the menu edits a note for all apps (who you are, tone,
spelling) and one for the app you were last in, appended after it. Both go into the prompt
header.

### Latency design

- The prompt ends *before* the partial word. Token healing masks the first decode steps to
  tokens consistent with what you typed, so the cached prefix is identical for a whole word
  and each keystroke prefills 0–2 tokens.
- Generated tokens are rolled back out of the KV cache after every suggestion.
- No fixed debounce: each keystroke cancels the in-flight job between decode steps.
- Typing through a visible suggestion, backspacing inside it, and repeated Tabs reuse it
  with no inference at all.
- **Prefetch** (mains power only): while a suggestion is on screen, the engine computes the
  one that would follow it, so taking the whole suggestion shows the next one instantly.
  Any keystroke cancels it between decode steps. With a 150 ms reaction time it served 6% of
  suggestions instantly at no latency cost (p50 64 ms with, 67 ms without).

Measured with `ft-replay` on an M3 Pro (Qwen3-1.7B-Base Q4_K_M, sample email):
41–44% of keystrokes saved, 3.5–3.7 characters per Tab, model suggestions p50 74–85 ms and
p90 106–119 ms, 1 token prefilled per keystroke (p50).

## Install

- **DMG:** download `Foretype-<version>.dmg` from the releases page, drag Foretype to
  Applications, open it. (Release builds are signed and notarized; see `RELEASING.md`.)
- **Homebrew:** `brew install --cask foretype` once the cask is published.
- **From source:** see Build below.

Requirements: Apple Silicon, macOS 14 (Sonoma) or later, 8 GB of RAM (16 GB recommended).

On first launch a setup window walks through Accessibility (required), Screen Recording
(optional, for screen context) and the model download. Updates arrive through Sparkle in
release builds (menu: Check for Updates…).

### Models

The menu's **Model** submenu lists the catalog (`models/catalog.json`, shared by every
shell): Qwen3 base models in three tiers, each pinned to a SHA-256 and verified after
download (interrupted downloads resume; a mismatch is discarded).

| Model | Size | Picked for |
|---|---|---|
| Qwen3 0.6B Base Q8_0 | 0.6 GB | under 12 GB of RAM |
| Qwen3 1.7B Base Q4_K_M | 1.1 GB | 12 GB and up (default) |
| Qwen3 4B Base Q4_K_M | 2.5 GB | opt-in on 16 GB+ (about twice the latency) |

**Use a Server Instead…** points Foretype at your own inference server:

- a llama.cpp `llama-server`: same suggestions as the built-in engine (token healing via a
  GBNF grammar); measured 40.7% keystrokes saved, the same as built-in, at p50 130–147 ms
  over HTTP against 79 ms in-process;
- any OpenAI-compatible completions endpoint (Ollama, LM Studio, a cloud provider): works,
  but with no grammar it completes half-typed words less well (20% saved on the same text).
  An API key, if any, is kept in the Keychain.

## Build

Requirements: Xcode command-line tools, Rust (`brew install rust cmake`).

```bash
scripts/build-mac.sh          # build/Foretype.app (ad-hoc signed unless FORETYPE_SIGN_IDENTITY is set)
scripts/package-mac.sh        # build/Foretype-<version>.dmg, plus notarization, appcast item and cask when configured
```

`FORETYPE_SPARKLE=1` adds the Sparkle updater (fetched by SwiftPM); see `RELEASING.md` for
signing, notarization and Sparkle keys.

## Run

From source: put a GGUF base model in `~/Library/Application Support/Foretype/Models/` or
set `FORETYPE_MODEL=/path/to/model.gguf`, open `build/Foretype.app` and grant Accessibility
when asked. The menu-bar icon has the on/off switch, suggestion length, per-app toggle,
personalization, custom instructions, model and setup.

| Key | Action |
|---|---|
| Tab | insert the next word |
| key above Tab (` or §) | insert the whole suggestion |
| Esc | dismiss (no new suggestion until you type) |
| Option+Tab | a real Tab |
| Ctrl + key above Tab | suggest here even where Foretype normally stays quiet (this line only) |
| Ctrl+Opt+Cmd + key above Tab | snooze suggestions in the current app for 5 minutes |

### Per-app behaviour

- **Terminals** (Terminal, iTerm, WezTerm, Alacritty): suggestions only when the caret line
  is an AI-agent prompt (an optional `│`/`┃` border, then `> `, `› ` or `▌ `). Only the
  prompt's own text is used as the document; the scrollback reaches the model as screen
  context. Shell prompts (`$`, `%`, `❯`) never get suggestions.
- **Insertion**: keystrokes by default. Apps can be set to `paste`, `paste-long` (paste
  from 40 characters) or `first-word-then-paste`. Paste borrows the clipboard, marks the
  item transient so clipboard managers skip it, and restores the previous clipboard. It is
  used only when macOS clipboard access for Foretype is "always allow" (macOS 15.4+ asks
  otherwise); without that it falls back to keystrokes, never leaving your clipboard
  overwritten.
- **Chromium** reports a font size but no font name; Foretype measures the on-screen width
  of the last few characters and picks the matching font family.
- **Power**: the model is unloaded after 5 idle minutes (about 1 GB freed) and reloaded on
  the next keystroke; on battery, mid-word suggestions wait 80 ms for the next keystroke.

## Development

- `cargo test` in `core/` runs the unit tests (word splitting, prompt stability, session
  reuse, policy, encrypted history, profile, recorder).
- `ft-replay MODEL TEXT_FILE` replays typing through the core and reports keystrokes saved,
  characters per accept and latency, with no UI. `--corpus FILE.jsonl` replays a corpus
  (the Phase 0 one is `spike/eval/corpus/corpus.jsonl`), `--think MS` adds a reaction time,
  and `--personal-loo` runs the leave-one-out personalization comparison.
- `scripts/e2e-textedit.sh` drives a new TextEdit document with synthetic keystrokes
  (Tab, accept-all, mid-word, Esc, Option+Tab; `FORETYPE_INSERTION=paste` repeats it with
  paste insertion). `scripts/e2e-terminal.sh` opens a Terminal window running `tee` (so
  nothing reaches a shell) and checks ordinary lines, agent prompts, force and snooze. Both
  restrict Foretype to the app under test (`FORETYPE_ONLY_APPS`), wait for the user to be
  idle, and pause or abort if focus leaves that app.
- `FORETYPE_DEBUG=1` logs snapshots, caret strategy, suggestions and latency to stderr.
- `FORETYPE_ONLY_APPS=bundle.id,...` restricts reading and suggestions to those apps. Use
  it whenever you run a dev build on a machine you are also working on.
- `Foretype --ocr-selftest` renders a fake chat window and checks OCR and row assembly;
  `Foretype --font-selftest` checks the width-based font matcher (no permissions needed).
  `Foretype --download-selftest MODEL_ID` downloads and verifies one catalog model
  (`FORETYPE_MODEL_BASE_URL` and `FORETYPE_MODELS_DIR` point it at a local server and a
  scratch folder).
- CI (`.github/workflows/ci.yml`, manual trigger only for now) runs the unit tests, builds the app, runs the self-tests
  and replays the self-written corpus documents with the 0.6B model on CPU. `ft-replay ... --screen FILE` adds screen text to a replay.
- **Accessibility grants and ad-hoc signing:** macOS ties the grant to the exact build, so
  every rebuild of an ad-hoc-signed `Foretype.app` needs the Accessibility entry removed
  and re-added. Sign with a stable identity (`FORETYPE_SIGN_IDENTITY`) to avoid that. A
  bare `mac/.build/release/Foretype` started from a terminal uses the terminal's own grant.

## Known limitations (MVP)

- Dense full-attention models only (Qwen3 base). Gemma 4 and Qwen3.5 need KV state
  snapshots (sliding-window / recurrent layers can't roll back).
- Per-app insertion overrides are in place but every app still defaults to keystrokes;
  entries need testing app by app.
- Screen context has only been tested through the OCR self-test and replays; live window
  capture needs the Screen Recording grant on `Foretype.app`, which the dev test setup
  doesn't have.
- No model download UI, autocorrect, emoji, phrase beam search or Gemma 4 support yet.
- The personalization menu and the Custom Instructions window have not been exercised in
  the automated tests; the recorder, history and bias are covered by unit tests and replays.
- Notarization and the Sparkle feed are wired up but have not been exercised: they need a
  Developer ID certificate, notary credentials and Sparkle keys (`RELEASING.md`). The
  release workflow is an untested template.
- The setup window, Model menu and server dialog have not been exercised in the automated
  tests; the downloader is covered by `--download-selftest` and the server backends by
  replays against a local llama-server.

## Licensing

Core and shell: MIT OR Apache-2.0. `compat/apps.json`: CC0-1.0. Default models (Qwen3
base) are Apache-2.0 and are not bundled.
