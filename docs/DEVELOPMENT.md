# Development guide

## Prerequisites

- Apple Silicon Mac, macOS 14+ (developed on macOS 27.0.1, M3 Pro, 18 GB).
- Xcode command-line tools (Xcode itself is not required; `xcodebuild` is not used).
- Rust and cmake: `brew install rust cmake`.
- Models: `~/Library/Application Support/Foretype/Models/*.gguf` (installed on the
  developer Mac: Qwen3 0.6B Q8_0, 1.7B Q4_K_M, 4B Q4_K_M; see `models/catalog.json`).

Always export `MACOSX_DEPLOYMENT_TARGET=14.0` when building the core, or the static library
targets the host macOS and the Swift link warns ("built for newer macOS version").

## Build

```bash
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --release --manifest-path core/Cargo.toml          # libforetype_core.a + ft-replay
(cd mac && swift build -c release)                              # mac/.build/release/Foretype
scripts/build-mac.sh                                            # both, then build/Foretype.app (ad-hoc signed)
FORETYPE_SPARKLE=1 scripts/build-mac.sh                         # with Sparkle (fetched by SwiftPM, .build-sparkle/)
scripts/package-mac.sh                                          # DMG (+ notarization etc. when configured, see RELEASING.md)
```

- The first core build compiles llama.cpp (Metal) through `llama-cpp-sys-2` and cmake,
  about a minute.
- `core/build.rs` links clang's runtime (`libclang_rt.osx.a`) into the test binaries and
  `ft-replay`: llama.cpp's `@available` checks call `___isPlatformVersionAtLeast`, and rustc
  links with `-nodefaultlibs`. The Swift link goes through clang and doesn't need it.
- The Swift package links `core/target/release/libforetype_core.a` (path computed in
  `mac/Package.swift`) plus Metal, Accelerate, ScreenCaptureKit, Vision, IOKit, Carbon and
  libc++.
- `dsymutil` warnings about `unicode.cpp.o` symbols during the Swift link are harmless.

## Tests

| What | Command | Needs |
|---|---|---|
| Core unit tests (25+) | `cargo test --release --manifest-path core/Cargo.toml` | nothing |
| Font matcher | `mac/.build/release/Foretype --font-selftest` | nothing |
| OCR + row assembly | `mac/.build/release/Foretype --ocr-selftest` | nothing (first-ever run compiles Vision models, ~30 s) |
| Model download + verify | `FORETYPE_MODEL_BASE_URL=http://127.0.0.1:PORT FORETYPE_MODELS_DIR=/tmp/x mac/.build/release/Foretype --download-selftest qwen3-0.6b-base-q8` | a local `python3 -m http.server` serving the GGUF |
| Replay quality/latency | `ft-replay` (below) | a model |
| TextEdit end-to-end | `FORETYPE_MODEL=... scripts/e2e-textedit.sh` | Accessibility, user idle |
| Terminal end-to-end | `FORETYPE_MODEL=... scripts/e2e-terminal.sh` | Accessibility, user idle |

Unit tests cover word splitting, prompt stability, the screen and examples sections,
session reuse, the policy gate and agent prompts, the compat DB, the encrypted history
(round trip, wrong key, no plaintext on disk), the profile, example selection, the
recorder, the catalog, word limiting and the HTTP backend config.

### ft-replay

Replays typing through the core exactly as a shell would, with a simulated user who presses
Tab whenever the suggestion's next word is what they would type next.

```bash
R=core/target/release/ft-replay
M="$HOME/Library/Application Support/Foretype/Models/Qwen3-1.7B-Base.Q4_K_M.gguf"
$R "$M" scripts/fixtures/email.txt --prime 400 --chars 500 -v          # one text, verbose accepts
$R "$M" --corpus eval/corpus.jsonl                                      # 53 documents
$R "$M" --corpus eval/corpus.jsonl --only sw- --personal-loo --strength 1   # personalization, leave-one-out
$R "$M" --corpus eval/corpus.jsonl --only sw-email --think 150          # 150 ms reaction time (prefetch)
$R "$M" scripts/fixtures/chat-reply.txt --prime 0 --screen scripts/fixtures/chat-screen.txt  # screen context
$R - scripts/fixtures/email.txt --backend llama-server --url http://127.0.0.1:18431             # server backend
$R "$M" --corpus eval/corpus.jsonl --only sw- --cpu                     # no Metal (CI)
```

Other flags: `--words N` (suggestion length), `--no-prefetch`, `--no-examples`, `--app NAME`,
`--remote-model NAME` (OpenAI-compatible). `FORETYPE_DEBUG=1` prints per-request prefill
and generation timings.

Output: keystrokes saved, characters per accept, accept count, model latency p50/p90, and
how many keystrokes were served by `model`, `typeThrough`, `cache` or `policy`.

### End-to-end scripts

Both scripts start `mac/.build/release/Foretype` with `FORETYPE_DEBUG=1` and
`FORETYPE_ONLY_APPS` set to the app under test, wait until the user has been idle for
`$IDLE` seconds (default 20), and drive keystrokes with `build/ftdrive` (compiled from
`scripts/ftdrive.swift`). Typing pauses while another app is frontmost and aborts after 2 s.

- `e2e-textedit.sh`: new unsaved document with `scripts/fixtures/email.txt`; checks Tab ×2,
  accept-all, mid-word completion, Esc then a real Tab, Option+Tab. Writes
  `build/e2e/result.txt` and `build/e2e/foretype.log`. Expected document tail:
  `My suggestion is that we do the first part Thanks again for the notes, Let me\t know\t`
  with the 1.7B model (greedy decoding is deterministic). `FORETYPE_INSERTION=paste`
  repeats it through paste insertion.
- `e2e-terminal.sh`: opens a Terminal window from a `.command` file running `tee` (nothing
  reaches a shell; every entered line lands in `build/e2e-terminal/typed-lines.txt`).
  Checks: no suggestion on an ordinary line, the force hotkey (current line only), agent
  prompt suggestions on a `> ` line, snooze.

**Before running either, tell the user** (they take over the keyboard focus), and if
Cotypist is running, ask before quitting it (it also intercepts Tab). TextEdit sometimes
opens an empty "Untitled" window on activation; close unmodified untitled windows
afterwards.

The ghost overlay can't be screenshotted from a Claude session: screen capture there is
filtered to approved apps, and a dev binary can't be approved. Ask the user to look.

## Debugging

`FORETYPE_DEBUG=1` logs lines like:

```
[  9.400] accept word via keystrokes " do"
[  7.544] rev 27 model 83ms TextEdit caret=prevEdge(zeroHigh) 686,384 h14 -> " do the first part"
[foretype] rev=27 prefill=1 tok/1.4ms gen=6 total=82.0ms queue+total=83.1ms stop=words " do the first part"
screen: 412 chars from Microsoft Teams in 210 ms
```

`caret=` shows the strategy (`prevEdge`, `prevEdge(zeroHigh)`, `zero`, `zero+offset`,
`zero(wrapped)`, `none` → mirror card). `FORETYPE_LLAMA_LOGS=1` keeps llama.cpp's own logs.

## macOS permissions and signing (TCC)

- **Responsible process.** A CLI started from a terminal is attributed to its parent app:
  a bare `mac/.build/release/Foretype` run from the Claude app's terminal uses Claude's
  Accessibility, clipboard and Screen Recording grants. That's the easy dev loop (but always
  with `FORETYPE_ONLY_APPS`).
- **Bundled app.** `build/Foretype.app` is its own identity (`dev.foretype.Foretype`). With
  ad-hoc signing the grant is tied to the exact build's cdhash: after every rebuild, remove
  the Accessibility entry with − and add it again (toggling isn't enough). A stable signing
  identity (`FORETYPE_SIGN_IDENTITY`) fixes this. There is none on the developer Mac yet.
- SwiftPM's linker-signed ad-hoc binaries can never be granted ("Failed to match existing
  code requirement"); `build-mac.sh` re-signs fully.
- Accessibility alone is enough for both event taps (no Input Monitoring) on macOS 27.
- Screen Recording: macOS 15+ re-prompts monthly. Only the bundled app requests it.
- AppleScript control of Terminal triggers an Automation consent prompt; avoid it in tests.
- On macOS 27, system-wide `AXFocusedApplication` always fails (`cannotComplete`); the
  tracker uses `NSWorkspace.frontmostApplication` and `AXUIElementCreateApplication(pid)`.

## Common tasks

**Add or change an app rule.** Edit `compat/apps.json` (bundle ID → `disabled`,
`agent_prompt_only`, `insertion`, `prime`, `note`). It's compiled into the core, so rebuild.
Add a policy test in `core/src/policy.rs` if the behaviour is new.

**Add a model.** Add an entry to `models/catalog.json` with the exact `bytes` and `sha256`
(compute with `shasum -a 256`), `tier`, `min_ram_gb` and `license`. Only dense,
full-attention models work until KV snapshots exist. Run the corpus replay and record the
results in `docs/MEASUREMENTS.md`.

**Change the C ABI.** Update `core/src/ffi.rs`, `core/include/foretype_core.h` and
`mac/Sources/Foretype/Engine.swift` together; document JSON shape changes in
`docs/ARCHITECTURE.md`.

**Add a setting.** Rust `Settings` (with a default) → Swift `AppSettings` property and
`coreDict` key → menu or window UI → `Controller.applySettings()` pushes it.

**Change the prompt format or decoding.** Keep everything per-keystroke at the end of the
prompt (cache stability). Replay the corpus before and after.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `GGML_ASSERT([rsets->data count] == 0)` at exit | A llama context outlived the Metal device; `Engine::drop` frees context, model, backend in order. Call `ft_engine_free` before exit |
| Link error `___isPlatformVersionAtLeast` in tests | `core/build.rs` must link `libclang_rt.osx.a` |
| "was built for newer 'macOS' version" | Build the core with `MACOSX_DEPLOYMENT_TARGET=14.0` |
| Bundled app does nothing | Accessibility not granted for this exact build; re-add it |
| No suggestions in Chrome | Check `AXEnhancedUserInterface` priming; Arc/Dia need chrome://accessibility "Text Metrics" |
| `osascript` → `AppleEvent timed out (-1712)` | A pending Automation consent dialog; avoid AppleScript to that app |
| e2e "focus left TextEdit" at start | Activation delayed; the script uses `open -a` and waits 5 s |
| `hdiutil create` deprecation warning | Harmless for now; `diskutil image create` is the replacement |
