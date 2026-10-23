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
scripts/make-signing-cert.sh                                    # once, run it yourself: the stable signing identity (below)
scripts/build-mac.sh                                            # both, then build/Foretype.app ("Foretype" if present, else ad hoc)
FORETYPE_SPARKLE=1 scripts/build-mac.sh                         # with Sparkle (fetched by SwiftPM, .build-sparkle/)
scripts/package-mac.sh                                          # DMG, appcast.xml, cask (see RELEASING.md)
scripts/sparkle-local-test.sh                                   # waiting update shown, then silent update 0.0.1 -> 0.0.2, feed on 127.0.0.1
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
| Font matcher; ghost font from the run before the caret (soft wrap, mixed sizes, zoom) | `mac/.build/release/Foretype --font-selftest` | nothing |
| OCR + row assembly | `mac/.build/release/Foretype --ocr-selftest` | nothing (first-ever run compiles Vision models, ~30 s) |
| Statistics (counts, day buckets, 30-day window, reset, no text stored) | `mac/.build/release/Foretype --stats-selftest` | nothing (in-memory, never the app's defaults) |
| Pixel caret detectors | `mac/.build/release/Foretype --caret-selftest` | nothing |
| Screen geometry across displays (global and Cocoa coordinates, displays left of, above and below the primary, mixed 1x/2x scales, cards at a display's top edge) | `mac/.build/release/Foretype --geometry-selftest` | nothing (made-up layouts; no second display) |
| About You store (JSON for the core, sealing, wrong key, defaults) | `mac/.build/release/Foretype --about-selftest` | nothing (key in memory; never the Keychain or the real file) |
| Pause and power rules (decisions, Resume Anyway, migration, saved pause) | `mac/.build/release/Foretype --pause-selftest` | nothing (a defaults suite of its own) |
| Translations (every key, same placeholders) | `python3 scripts/check-localization.py` | nothing |
| About You fills in TextEdit (email, phone from its typed start, name after Regards, no match, nothing in the log) | `FORETYPE_MODEL=... scripts/e2e-about-you.sh` | Accessibility, user idle (fictional details from `FORETYPE_ABOUT_YOU`; the stored ones are untouched) |
| Typing aids in TextEdit (emoji, autocorrect, typo gate, mid-line) | `FORETYPE_MODEL=... scripts/e2e-typing-aids.sh` | Accessibility, user idle |
| Emoji/autocorrect Tab replacement in a web field | `FORETYPE_MODEL=... [MARKERS=1] scripts/e2e-browser-aids.sh` | Accessibility, user idle (throwaway Chrome profile) |
| Download resumes after a relaunch | `FORETYPE_MODEL_BASE_URL=http://127.0.0.1:PORT FORETYPE_MODELS_DIR=/tmp/x mac/.build/release/Foretype --resume-selftest qwen3-0.6b-base-q8` | a local server with Range support, slow enough to pause mid-way |
| Pixel caret vs AX caret | `scripts/caret-measure.sh [APP BUNDLE_ID FIXTURE]` | Accessibility and Screen Recording (the terminal's), user idle |
| Pixel caret in the app (nothing typed) | `FORETYPE_MODEL=... scripts/e2e-pixel-caret.sh [APP BUNDLE_ID FIXTURE]` | same |
| Model download + verify | `FORETYPE_MODEL_BASE_URL=http://127.0.0.1:PORT FORETYPE_MODELS_DIR=/tmp/x mac/.build/release/Foretype --download-selftest qwen3-0.6b-base-q8` | a local `python3 -m http.server` serving the GGUF |
| Replay quality/latency | `ft-replay` (below) | a model |
| TextEdit end-to-end | `FORETYPE_MODEL=... scripts/e2e-textedit.sh` | Accessibility, user idle |
| Terminal end-to-end | `FORETYPE_MODEL=... scripts/e2e-terminal.sh` | Accessibility, user idle |
| Fresh Chrome end-to-end (nothing typed) | `FORETYPE_MODEL=... scripts/e2e-chrome-fresh.sh` | Accessibility, user idle |
| Pause through the URL scheme: no work while paused, model freed, resume, timed pause ends by itself; CPU, wakeups and memory per phase (nothing typed unless `TYPE=1`) | `FORETYPE_MODEL=... [TYPE=1] [SAMPLE=20] scripts/e2e-pause.sh` | Accessibility for `build/Foretype.app` (signed with the Foretype identity), user idle |
| Inline ghost text while typing in a chat composer with no AX caret (wrap, new line, list, new field) | `FORETYPE_MODEL=... scripts/e2e-inline-caret.sh [ce\|textarea]` | Accessibility and Screen Recording, user idle (throwaway Chrome profile; the page types into itself) |
| Cache rollback | `ft-replay MODEL --corpus eval/corpus.jsonl --check-cache [--long]` | a model |
| Sparkle update: with automatic install off the menu line, the Settings line, the icon's dot and the update window it opens; then the silent install | `scripts/sparkle-local-test.sh`, then Check for Updates… in the printed app | nothing (`RELEASING.md`); Sparkle's window appears for a few seconds |
| Benchmark a Mac | `scripts/bench-mac.sh [--only sw-]`, `ENERGY=1` for mJ per suggestion | the catalog models |
| GPU energy of a command | `swiftc -O tools/energy/energy.swift -o build/ft-energy && build/ft-energy -- CMD` | nothing (CPU/DRAM: `sudo powermetrics`) |
| What turns on Chrome's web tree | `tools/spike/probe/run_chrome_triggers.sh` (`TRIGGERS="none enhanced"` for a subset) | Accessibility (the terminal's grant) |
| Unprimed Chrome (superseded: reads before Chrome's 2 s wait ends) | `tools/spike/probe/run_unprimed_chrome.sh` | AXProbe.app granted Accessibility |

Unit tests cover word splitting, prompt stability, the screen and examples sections,
session reuse, the policy gate and agent prompts, the compat DB, the encrypted history
(round trip, wrong key, no plaintext on disk), the profile, example selection, the
recorder, the catalog, word limiting, the HTTP backend config, and the About You fills
(every cue kind, sign-offs, case mismatch, nothing to fill, secure fields, disabled apps,
mid-line, the writer line only for local backends).

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
$R "$M" --corpus eval/corpus.jsonl --check-cache --docs 4 --chars 200   # cache reuse == fresh context?
$R "$M" --corpus eval/corpus.jsonl --check-cache --docs 3 --long        # same, prompts past 512 tokens
$R "$M" --corpus eval/corpus.jsonl --beam 3                             # phrase beam search
$R "$M" --corpus eval/corpus.jsonl --mid-line-eval --typed 1            # mid-line word accuracy
$R "$M" --corpus eval/corpus-hi.jsonl                                   # Hindi (Devanagari); corpus-hinglish.jsonl too
$R "$M" --corpus eval/corpus-hi.jsonl --token-cost                      # chars per token, tokens per word
$R "$M" --corpus eval/corpus.jsonl --details eval/details.json          # About You fills
$R "$M" --corpus eval/corpus.jsonl --details eval/details.json --details-in-prompt  # + writer line
$R "$M" --corpus eval/corpus.jsonl --default-instructions              # with the shipped default notes
$R "$M" --corpus eval/corpus.jsonl --instructions notes.json            # other notes (same JSON format)
swiftc -O tools/spell-map/main.swift mac/Sources/Foretype/Speller.swift -o build/spell-map
build/spell-map eval/corpus.jsonl > build/spell-map.json                # the app's spell verdicts
$R "$M" --corpus eval/corpus.jsonl --spell build/spell-map.json         # typo gate + autocorrect
$R "$M" --corpus eval/corpus-multiwindow.jsonl --context-mode both      # other app's text + focused window (none|focused|other|both)
$R "$M" --corpus eval/corpus-multiwindow.jsonl --ctx-bench --n-ctx 8192 # long-context latency and memory, one n_ctx per process
scripts/bench-context.sh                                                # both, for every installed model and n_ctx 2048/4096/8192
```

Other flags: `--words N` (suggestion length), `--no-prefetch`, `--no-examples`, `--app NAME`, `--n-ctx N`
(context size, default 2048 as in the app),
`--remote-model NAME` (OpenAI-compatible). `FORETYPE_DEBUG=1` prints per-request prefill
and generation timings.

Without `--default-instructions` or `--instructions` the replay has no custom instructions,
so its numbers compare with the older ones in `docs/MEASUREMENTS.md`; the app itself starts
with the defaults (`core/data/default-instructions.json`). With per-app notes, the corpus
apps (`Mail`, `Slack`, `Teams`, `Messages`, `Notes`, `a document`) stand in for their bundle IDs.

Output: keystrokes saved, characters per accept, accept count, model latency p50/p90, the
first suggestion of each document p50/p90 (it prefills the whole header), and
how many keystrokes were served by `model`, `typeThrough`, `cache`, `details` or `policy`.
With `--details`, the simulated user takes a fill other than a name only if all of it is
what comes next (one Tab inserts all of it).

### Pausing, power rules and the URL scheme

- `FORETYPE_DEBUG` logs `paused: true|false`, `tracker started|stopped`, `pause: ...` (the
  user's pause, set-asides), `power: battery=... lowPower=... thermal=...` on every power
  change, `session: <notification>` and the core's `engine paused: model unloaded`.
- Only the bundle has the `foretype://` scheme. Send to a running dev bundle with
  `open -g -a build/Foretype.app "foretype://pause?minutes=0.1"` (fractions work: 6 s). If
  that copy isn't running, `open -a` launches it without `FORETYPE_ONLY_APPS`, so check
  first (`scripts/e2e-pause.sh` does). A plain `open foretype://...` goes to whichever copy
  LaunchServices picks, possibly the installed app.
- The dev bundle has the installed app's bundle ID, so it shares its UserDefaults: a pause
  "until I resume" set while testing is still there for the installed app (once it knows
  pausing). Test with timed pauses, or resume before quitting.
- Low Power Mode: System Settings ▸ Battery, or `sudo pmset -a lowpowermode 1` (and `0`).
  The thermal rules can't be triggered on demand; `PauseState.selfTest` covers them.

### Driving Foretype's own windows

Screen-control tools usually can't target menu-bar (`LSUIElement`) apps, so `build/ftdrive`
(`swiftc -O scripts/ftdrive.swift -o build/ftdrive`) also talks Accessibility:

```bash
build/ftdrive menu dev.foretype.Foretype                       # list the menu-bar menu
build/ftdrive menu dev.foretype.Foretype "Custom Instructions…" # press an item (walks submenus)
build/ftdrive menu dev.foretype.Foretype Model "Delete a Model" # a last item with a submenu lists it
build/ftdrive menu dev.foretype.Foretype Model "Qwen3 0.6B*"   # trailing * matches by prefix (live titles)
build/ftdrive windows dev.foretype.Foretype                    # titles, buttons, texts, CGWindowIDs
screencapture -x -o -l WINDOW_ID shot.png                      # one window, from that list
build/ftdrive press dev.foretype.Foretype Cancel               # press a button by title
build/ftdrive press dev.foretype.Foretype Statistics           # Settings tabs are toolbar buttons
FTDRIVE_HOLD=3 build/ftdrive menu dev.foretype.Foretype &      # keep the menu open for a screenshot
```

A numeric pid works in place of the bundle ID (one process of an app that runs several);
`ftdrive raise PID` brings a process to the front and `ftdrive front-pid` prints the current
one. For test documents: `ftdrive title PID` (focused window title), `ftdrive frame PID`
(its frame, for `screencapture -R`), `ftdrive caret PID TITLE POS` (moves the caret with
`AXSelectedTextRange`, only while PID is frontmost with TITLE in front), `ftdrive close PID
TITLE` (presses that window's close button; an unmodified document closes silently) and
`ftdrive quit PID`.

### Pixel caret

- `Foretype --caret-selftest` renders a line of text with a caret (Helvetica, Georgia,
  Menlo, the system font and Times; 1 and 2 pt carets; accent, black and dark-mode white;
  1× and 2×), runs the blink and verify detectors and checks that the caret is found within
  0.5 pt, that glyph stems (`l`, `|`, `1`) next to it are never taken for a caret when it is
  off, that text changing between captures is rejected, and the width advance.
- `scripts/caret-measure.sh` opens a copy of `scripts/fixtures/caret-lines.txt` (or the
  `.rtf`, Helvetica Light 15) in an app, then `Foretype --caret-measure PID TITLE` moves the
  caret to the middle and the end of each line with `AXSelectedTextRange` and compares the
  blink and verify results and the width advance (host font, and the fallback font with the
  learned width scale) with the AX caret. It also reports the raw previous-character rect,
  which shows a constant AX offset if an app has one. `--caret-measure` refuses to run
  unless `FORETYPE_ONLY_APPS` names the app, and stops when the app or the document leaves
  the front or the user touches the keyboard or mouse.
- `scripts/e2e-pixel-caret.sh` runs the app (restricted to the app under test) on a copy of
  the RTF fixture, moves the caret to line ends and along a line, screenshots the window
  region after each step to `build/e2e-pixel/` and prints the `pixel caret` and `caret=`
  log lines. `PRELAUNCH=1` starts the app before opening the document. `FORETYPE_CARET=pixel` (or `ax`) overrides every app's `caret` rule, so
  `FORETYPE_CARET=pixel scripts/e2e-pixel-caret.sh TextEdit com.apple.TextEdit` checks the
  integration where the AX caret is known to be right.
- All three wait for an unlocked screen and 20 s of user idle (a locked screen has no key
  window, so no caret, and Accessibility returns empty windows), close the document and
  quit the app only if they started it.

- A button that opens an `NSAlert` doesn't answer the press until the alert closes
  (`runModal`); `ftdrive press` then reports "the app is busy" and stops. Press the alert's
  buttons with a second `ftdrive press`. Titles compare without a trailing "…", so
  "Delete" also matches "Delete…"; the frontmost alert is walked first.
- For the first 15–90 s after launch (and now and then later) the app's windows can show
  up as bare "Foretype" with no children; the menu still works. Retry `windows` until the
  buttons appear. `screencapture -l` doesn't depend on it.
- To try the Settings window's Model tab without touching real files, point
  `FORETYPE_MODELS_DIR` at a scratch folder of APFS clones (`cp -c` of the installed
  models: instant, no extra space) plus a dummy `NAME.gguf.part`. For downloads, serve
  bytes from 127.0.0.1 with Range support and point `FORETYPE_MODEL_BASE_URL` at it; the
  download fails its checksum at the end, as it should. A bundled build that has no
  Accessibility grant (every fresh ad-hoc build) never starts the engine, so it reads
  nothing; export the defaults domain first and restore it afterwards. A build signed with
  "Foretype" keeps its grant and does start the engine: launch it with
  `open -n --env FORETYPE_ONLY_APPS=...`, or build with `FORETYPE_SIGN_IDENTITY=-`.

### End-to-end scripts

The scripts start `mac/.build/release/Foretype` with `FORETYPE_DEBUG=1` and
`FORETYPE_ONLY_APPS` set to the app under test, wait until the user has been idle for
`$IDLE` seconds (default 20; 10 for Chrome), and drive keystrokes with `build/ftdrive`
(compiled from `scripts/ftdrive.swift`). Typing pauses while another app is frontmost and
aborts after 2 s.

- `e2e-textedit.sh`: new unsaved document with `scripts/fixtures/email.txt`; checks Tab ×2,
  accept-all, mid-word completion, Esc then a real Tab, Option+Tab. Writes
  `build/e2e/result.txt` and `build/e2e/foretype.log`. Expected document tail:
  `My suggestion is that we do the first part Thanks again for the notes, Let me\t know\t`
  with the 1.7B model (greedy decoding is deterministic). `FORETYPE_INSERTION=paste`
  repeats it through paste insertion. `WINDOW_BOUNDS=LEFT,TOP,RIGHT,BOTTOM` (global points)
  moves the document window, e.g. `100,-900,1000,-450` onto a display above the main one;
  the log's `show=inline at X,Y` should equal `caret=… X,Y`. The screenshots use TextEdit's
  `window 1`, which can be the empty Untitled window TextEdit opens at launch; trust the log.
- `e2e-terminal.sh`: opens a Terminal window from a `.command` file running `tee` (nothing
  reaches a shell; every entered line lands in `build/e2e-terminal/typed-lines.txt`).
  Checks: no suggestion on an ordinary line, the force hotkey (current line only), agent
  prompt suggestions on a `> ` line, snooze.
- `e2e-chrome-fresh.sh`: types nothing. Starts a separate Chrome with a throwaway profile on
  `tools/spike/probe/fixtures/testpage.html` and restricts Foretype to that process's pid
  (the user's own Chrome has the same bundle ID), raises it and waits up to 10 s for a
  suggestion (normally 2–3 s, see `docs/MEASUREMENTS.md`), screenshots the window region
  to `build/e2e-chrome/1-fresh.png`, then clears `AXEnhancedUserInterface` from outside and
  checks that Foretype primes again.
- `e2e-inline-caret.sh [ce|textarea]` (`WINDOW_POS=X,Y` opens the window there, in
  screen points from the main display's top left, e.g. on a display above it): sends no
  keystrokes. A throwaway-profile Chrome opens
  `scripts/fixtures/composer.html`, a chat composer (one `<p>` per line, like ProseMirror)
  that types into itself 6 s after its window is focused, at 110–190 ms per character, and
  pauses while it isn't: a first line that wraps, Enter and a second line, the field
  emptied, a numbered list, then a new field typed into 0.2 s after it takes focus.
  `FORETYPE_CARET=pixel` (the default here) forces the pixel caret as in apps with no AX
  caret. The window title names the segment; the script logs it, screenshots the window
  region about every second and counts how each suggestion was drawn per segment (the
  `show=inline|card|mirror` debug field) and the card-to-inline jumps. Add `bg` to the page's
  hash (`composer.html#ce,bg`) to have it type in a background window, for Accessibility
  probes that shouldn't take the front.

**Before running any of them, tell the user** (they take over the keyboard focus), and if
Cotypist is running, ask before quitting it (it also intercepts Tab). TextEdit sometimes
opens an empty "Untitled" window on activation; close unmodified untitled windows
afterwards.

The ghost overlay is its own window: the computer-use screenshot tool (filtered to approved
apps) and a window-only `screencapture -l` miss it. `screencapture -R` over the window's
region from a shell includes it (`e2e-chrome-fresh.sh` does this); otherwise ask the user to
look.

## Debugging

`FORETYPE_DEBUG=1` logs lines like:

```
[  9.400] accept word via keystrokes " do"
[  7.544] rev 27 model 83ms TextEdit caret=prevEdge(zeroHigh) 686,384 h14 show=inline -> " do the first part"
[foretype] rev=27 prefill=1 tok/1.4ms gen=6 total=82.0ms queue+total=83.1ms stop=words " do the first part"
screen: 412 chars from Microsoft Teams in 210 ms
```

`caret=` shows the strategy (`prevEdge`, `prevEdge(zeroHigh)`, `zero`, `zero+offset`,
`zero(wrapped)`, `pixel`, `pixel+advance`, `none` → mirror card), `after=` the characters
after the caret on its line when there are any (letters as `a`, others as `U+XXXX`),
`line=` the caret line's start index, `field=` the field's top and height, and `show=` how
the suggestion was drawn (`inline`, `card` under the caret, `mirror` above the
field, `hidden`). The pixel caret locator logs `pixel caret (blink|verify|solid): X,Y hH in
N frames M ms, width scale S`, `pixel caret: no blinking caret found in BUNDLE (field: WHY;
window: WHY)` and `pixel caret: no solid caret found in BUNDLE (N bars, direction D, from y
Y)`. WHY is `no capture of WxH pt` (ScreenCaptureKit returned nothing), `frame size changed`,
or `N frames of WxH px at Sx, P px changed, bars a/b/c/d/e (all/thin/filled/clear/quiet)`
with the first sizes in points: how many changed-pixel bars survived each filter (a caret
needs exactly one at the end; typing during the captures leaves many, a caret that never
blinks none). `capture: APP window N only through its display (full screen)` marks a window
that is captured through its display (D43); `rev N pixel caret moved the suggestion: show=...`
when a result moves (or shows) the suggestion. `FORETYPE_LLAMA_LOGS=1` keeps llama.cpp's own logs.

## macOS permissions and signing (TCC)

- **Responsible process.** A CLI started from a terminal is attributed to its parent app:
  a bare `mac/.build/release/Foretype` run from the Claude app's terminal uses Claude's
  Accessibility, clipboard and Screen Recording grants. That's the easy dev loop (but always
  with `FORETYPE_ONLY_APPS`).
- **Bundled app.** `build/Foretype.app` is its own identity (`dev.foretype.Foretype`), and
  TCC ties each grant to the app's designated requirement. An ad-hoc signature's requirement
  is the build's cdhash, so after every rebuild the entries under Accessibility and Screen
  Recording still look on but no longer apply. tccd logs `Failed to match existing code
  requirement for subject dev.foretype.Foretype and service kTCCServiceAccessibility` (or
  `kTCCServiceScreenCapture`); see it with
  `log stream --predicate 'subsystem == "com.apple.TCC"' --info`. Fix: remove the entry with
  − and add the app again (toggling isn't enough). On ad-hoc builds the setup window and
  Settings ▸ General say so under a permission that isn't granted.
- **Stable identity (one-time setup).** `scripts/make-signing-cert.sh` creates
  "Foretype", the self-signed code-signing certificate and key that releases are signed
  with too (D36), in the login keychain, and writes a PKCS#12 backup for the release workflow
  (`--import` installs a backup on another Mac). Run it yourself: it prints every command and asks first, changes no trust
  settings, needs no admin password, and `--remove` deletes it again. `build-mac.sh` then
  signs with it whenever it is present, and the designated requirement becomes
  `identifier "dev.foretype.Foretype" and certificate leaf = H"<certificate SHA-1>"`, the
  same for every build:

  ```bash
  scripts/make-signing-cert.sh
  scripts/build-mac.sh                     # "signed: Foretype, no hardened runtime; ..."
  codesign -dr - build/Foretype.app        # designated => identifier ... and certificate leaf = H"..."
  tccutil reset Accessibility dev.foretype.Foretype    # one last time: drop the ad-hoc entries
  tccutil reset ScreenCapture dev.foretype.Foretype
  open build/Foretype.app                  # allow both again; later rebuilds keep them
  ```

  Keychain Access shows the certificate as "not trusted"; neither codesign nor TCC checks
  trust (a hash match is enough), so it isn't added to the trust settings. If the first
  build asks whether codesign may use the key, enter the login password and click Always
  Allow. To check that a new build still satisfies an old grant without System Settings,
  save `codesign -dr - build/Foretype.app` before the rebuild and run
  `codesign -v -R '=<the text after "designated => ">' build/Foretype.app` after it:
  that is the check tccd makes. `FORETYPE_SIGN_IDENTITY=-` forces ad hoc for one build.
- **No hardened runtime for local builds.** The runtime enforces library validation, which
  only accepts libraries with the app's Team ID. Ad-hoc and self-signed signatures have
  none, so an app with Sparkle.framework embedded fails to launch ("Library missing").
  `build-mac.sh` adds `--options runtime --timestamp` only for an identity passed in
  `FORETYPE_SIGN_IDENTITY` (Developer ID), which notarization needs anyway.
- SwiftPM's linker-signed ad-hoc binaries can never be granted ("Failed to match existing
  code requirement"); `build-mac.sh` re-signs fully.
- Accessibility alone is enough for both event taps (no Input Monitoring) on macOS 27.
- Screen Recording: macOS 15+ re-prompts monthly. Only the bundled app requests it.
- AppleScript control of Terminal triggers an Automation consent prompt; avoid it in tests.
- **Keychain prompts.** A development binary reading Keychain items that the installed app
  created makes macOS ask for the login password: the item's access list names only the app
  that made it. On launch that's the About You key when `about-you.bin` exists, and the
  history key when personalization is on in the binary's defaults domain. The binary blocks
  in `Keychain.get` until someone answers. Run development binaries with
  `FORETYPE_ABOUT_YOU='{}'` (empty details, the store untouched), as `e2e-inline-caret.sh`
  and `e2e-textedit.sh` do, and never type the password into a prompt a test raised.
- On macOS 27, system-wide `AXFocusedApplication` always fails (`cannotComplete`); the
  tracker uses `NSWorkspace.frontmostApplication` and `AXUIElementCreateApplication(pid)`.

## Common tasks

**Add or change an app rule.** Edit `compat/apps.json` (bundle ID → `disabled`,
`agent_prompt_only`, `insertion`, `prime`, `caret`, `note`). Set `"caret": "pixel"` only
when `scripts/caret-measure.sh` shows the app's AX caret is wrong but plausible; an app with
no AX caret at all gets the pixel locator without a rule. It's compiled into the core, so rebuild.
Add a policy test in `core/src/policy.rs` if the behaviour is new.

**Add a model.** Add an entry to `models/catalog.json` with the exact `bytes` and `sha256`
(compute with `shasum -a 256`), `tier`, `min_ram_gb` and `license`. Dense,
sliding-window and recurrent/hybrid architectures all work (the engine picks the rollback
path at load). Run `ft-replay --check-cache` to confirm cache reuse gives the same
suggestions as a fresh context, then the corpus replay, and record both in
`docs/MEASUREMENTS.md`.

**Change the C ABI.** Update `core/src/ffi.rs`, `core/include/foretype_core.h` and
`mac/Sources/Foretype/Engine.swift` together; document JSON shape changes in
`docs/ARCHITECTURE.md`.

**Add a setting.** Rust `Settings` (with a default) → Swift `AppSettings` property and
`coreDict` key → a control in the Settings window (`PreferencesWindow.swift`, the pane's
`build()` and `refresh()`) and, if it is a common one, the menu → `host.settingsChanged()`
(`Controller.applySettings()`) pushes it and refreshes the window.

**Add or change a UI string.** Write it as `L("English text")` in Swift; a format takes
numbered arguments, `L("Delete %@?", name)` or `L("%1$@ of %2$@", a, b)`, all strings
(format numbers with `formatNumber`/`formatPercent` first). A count that changes the noun
goes through `LCount(n, "%@ files", one: "%@ file")` and needs an entry in every
`Localizable.stringsdict`, English included (count `%1$ld`, number `%2$@`). Add the
translation to each `mac/Localization/<lang>.lproj/Localizable.strings`, then run
`python3 scripts/check-localization.py`. Don't localize `Log.debug` lines, self-test
output, file paths, bundle IDs or anything sent to the core.

**Add a language.** Create `mac/Localization/<code>.lproj/` (an Apple language code, `hi`,
`de`, `pt_BR`) with `Localizable.strings` (copy `hi.lproj`'s and translate every value),
`Localizable.stringsdict` (the plural categories that language has, e.g. `one`/`few`/`many`/
`other` for Russian) and `InfoPlist.strings`. `build-mac.sh` picks up every `.lproj`
and lists it in `CFBundleLocalizations`; nothing else changes. Use the terms macOS itself
uses in that language: the system's own `.loctable` files hold them, e.g.
`plutil -extract hi xml1 -o - "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable"`.
Then check the Settings tabs and the setup window for clipped text (below).

**Try the app in another language.** Launch the bundle (only it has the `.lproj` folders)
with `-AppleLanguages`, restricted as always, after exporting the defaults domain:

```bash
defaults export dev.foretype.Foretype /tmp/ft-defaults.plist
open -n --env FORETYPE_ONLY_APPS=com.apple.TextEdit build/Foretype.app --args -AppleLanguages '(hi)'
build/ftdrive menu dev.foretype.Foretype                         # titles are now Hindi
build/ftdrive menu dev.foretype.Foretype "सेटिंग…"                # Settings…
build/ftdrive press dev.foretype.Foretype "आँकड़े"                 # a Settings tab
build/ftdrive windows dev.foretype.Foretype                      # CGWindowIDs for screencapture -l
build/ftdrive menu dev.foretype.Foretype "Foretype बंद करें"       # Quit
defaults import dev.foretype.Foretype /tmp/ft-defaults.plist
```

A fresh ad-hoc build has no Accessibility grant, so the setup window opens and the engine
never starts; that is enough to see every window. A build signed with "Foretype"
keeps its grant, so the engine starts too, restricted to TextEdit by `FORETYPE_ONLY_APPS`;
build with `FORETYPE_SIGN_IDENTITY=-` to see the setup window. `-AppleLanguages '(en)'`
gives English.

**Change the app icon or the menu-bar glyph.** The app icon is drawn by
`scripts/make-icon.swift` (CoreGraphics and CoreText, so the Command Line Tools are
enough): edit it, then run `swift scripts/make-icon.swift`, which rewrites
`mac/Resources/AppIcon.icns` (every iconset size, 16 to 1024 px, through `iconutil`) and the
README's `docs/images/icon.png`; commit both. `build-mac.sh` copies the `.icns` into the
bundle (`CFBundleIconFile`), `package-mac.sh` makes it the DMG's volume icon (when `SetFile`
is installed), and a bare `mac/.build/release/Foretype` loads it from the checkout. The tile
follows Apple's template (an 824 px rounded square on the 1024 px canvas): macOS 14 and 15
show it as drawn, macOS 26 and later scale it up to their own mask. Check what Finder shows
with `NSWorkspace.shared.icon(forFile:)` on the built app; Finder and the Dock cache icons,
so a changed icon may need `killall Dock` or a new path. The menu-bar glyph is drawn in code
(`mac/Sources/Foretype/Icons.swift`, `MenuBarIcon`), one picture per state; keep its edges
on the half-point grid so it is sharp at @2x.

**Change the prompt format or decoding.** Keep everything per-keystroke at the end of the
prompt (cache stability). Replay the corpus before and after.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `GGML_ASSERT([rsets->data count] == 0)` at exit | A llama context outlived the Metal device; `Engine::drop` frees context, model, backend in order. Call `ft_engine_free` before exit |
| Link error `___isPlatformVersionAtLeast` in tests | `core/build.rs` must link `libclang_rt.osx.a` |
| "was built for newer 'macOS' version" | Build the core with `MACOSX_DEPLOYMENT_TARGET=14.0` |
| Bundled app does nothing, or keeps asking for Screen Recording although it is on | The grant belongs to another ad-hoc build: remove the entry with − and add it again, or run `scripts/make-signing-cert.sh` once |
| No suggestions in Chrome | Check `AXEnhancedUserInterface` priming; Arc/Dia need chrome://accessibility "Text Metrics" |
| `osascript` → `AppleEvent timed out (-1712)` | A pending Automation consent dialog; avoid AppleScript to that app |
| e2e "focus left TextEdit" at start | Activation delayed; the script uses `open -a` and waits 5 s |
| `hdiutil create` deprecation warning | Harmless for now; `diskutil image create` is the replacement |
