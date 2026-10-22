# Changelog

Each `## X.Y.Z` section is a release: `scripts/release.sh` turns `## Unreleased` into one, and
the release notes are taken from it.

## Unreleased

### Ghost text stays at the caret while typing (2026-10-22)
- Chat composers in Chrome and Electron apps (Claude, Slack): Chromium's caret index and
  text ranges leave out the line break between paragraphs that its text counts, so on every
  line after the first the text before the caret ran the paragraphs together and the last
  letter typed read as text after the caret. The suggestion then showed in a card under the
  line (or not at all) and moved next to the caret only when you paused. Foretype now lines
  the two up and reads the right text on every line; an empty composer (which Chromium
  reports as one line break) counts as empty. Electron also moves its caret index a few
  milliseconds after inserting a typed letter; that moment is skipped, so the card no
  longer flashes under the line.
- Apps with no caret over Accessibility (pixel caret): once an app's caret has been seen, a
  new field, a new line or a wrapped line is found while you type with one capture (the
  caret is solid then), instead of showing the card above the field until a pause. Near the
  field's right edge the same capture follows the line as it wraps. A suggestion waits for
  that search (a few tens of milliseconds) rather than flashing the card. Empty fields are
  located on focus, so the first keystroke already has the caret.
- A corrected pixel position no longer turns a mid-line card into inline text over the rest
  of the line. When no word fits before the field's edge, the first word runs past it
  instead of a card above the field.
- `scripts/e2e-inline-caret.sh` with `scripts/fixtures/composer.html`, a chat composer that
  types into itself (no keystrokes sent), counts how each suggestion was drawn. The debug log
  has `show=inline|card|mirror|hidden`, `after=` (what follows the caret on its line),
  `line=` (the caret line's start index) and `field=` (the field's top and height).

## 0.1.0 (2026-10-22)

### Releases on GitHub and automatic updates (2026-10-22)
- `scripts/release.sh X.Y.Z` sets the version, dates this file, commits, tags `vX.Y.Z` and,
  after asking, pushes. `.github/workflows/release.yml` (macos-26) then runs the core tests,
  builds and signs the app, packages the DMG, signs it for Sparkle, writes `appcast.xml` and
  creates the GitHub release with the DMG, its checksum, the feed and `install.sh`.
- Install with one line, `curl -fsSL https://github.com/DaraSingh1998/foretype/releases/latest/download/install.sh | bash`,
  which checks the DMG's SHA-256 and copies the app to Applications, or download the DMG
  (one Open Anyway in Privacy & Security, since releases aren't notarized).
- Release builds check the latest release's `appcast.xml` daily, download a new version and
  install it once you have been idle for five minutes with no suggestion on screen, then
  reopen. Releases and local builds share the self-signed "Foretype" identity, so
  Accessibility and Screen Recording survive updates. Settings ▸ General shows the version,
  "Check for updates every day", "Install updates automatically" and Check Now.
- The update key's public half is in `packaging/sparkle-public-key.txt`; `package-mac.sh`
  signs DMGs with `tools/sparkle/edkey.swift`, so no Sparkle tarball is needed.
- `scripts/sparkle-local-test.sh` is now automatic: 0.0.1 finds 0.0.2 on a local feed,
  installs it silently and relaunches, signed like a release; it prints PASS/FAIL.
- `build-mac.sh` and `package-mac.sh` take `FORETYPE_OUT` (output folder).
- `THIRD_PARTY_NOTICES.md` lists llama.cpp, Sparkle, gemoji, the Rust crates, the models and
  the oasst1 excerpts; the app carries it in its Resources with the MIT, Apache, Sparkle and
  gemoji licence texts. `.gitignore` now ignores signing backups, keys and keychains.

### About You: your own details, filled in exactly (2026-10-22)
- New Settings tab **About You**: name, email, phone, company, job title, address and
  website, with a master switch and a switch per detail, and **Fill from My Card in
  Contacts…** (asks for Contacts access only when clicked).
- When the text clearly asks for a detail ("My email is ", "Call me on ", "Email:" at a line
  start, the line after "Regards,"), the ghost text is the exact value with a small tag
  ("your email"); Tab inserts it. It must match what was already typed; a name goes word by
  word, every other detail in one Tab. No model involved (`core/src/details.rs`, new FFI
  call `ft_engine_set_details`, new suggestion source `details`).
- A writer line in the prompt (`[Written by Name (Job title, Company)]`), on by default
  with its own switch, only for the built-in and Apple models (never sent to a server).
  Corpus replay: 41.9% keystrokes saved before, 42.0% with fills, 42.2% with fills and the
  writer line.
- Stored encrypted (`about-you.bin`, ChaCha20-Poly1305, key in the Keychain); never in
  UserDefaults; values never in debug logs (fills are logged by detail name, and pieces of
  the details are masked as `***` in any other logged text, model suggestions included).
  Hindi translations included.
- `ft-replay --details eval/details.json [--details-in-prompt]` replays the corpus with a
  user's details; `Foretype --about-selftest` checks the store and the JSON sent to the core;
  `scripts/e2e-about-you.sh` checks the fills in a new TextEdit document (9/9 passed).

### Local builds keep their permissions (2026-10-22)
- `scripts/make-signing-cert.sh` creates "Foretype", a self-signed code-signing
  identity, in the login keychain (you run it once; it prints each command and asks first;
  `--remove` deletes it), and writes a backup for the release workflow; `--import` installs a
  backup. Releases are signed with the same identity. `scripts/build-mac.sh` signs with `FORETYPE_SIGN_IDENTITY` if set
  (`-` forces ad hoc), else with "Foretype" if present, else ad hoc as before. The
  designated requirement is then the bundle ID plus the certificate, the same for every
  build, so Accessibility and Screen Recording grants survive rebuilds instead of silently
  failing to match (tccd: "Failed to match existing code requirement"). The hardened
  runtime still applies only to an explicit (Developer ID) identity: library validation
  would reject Sparkle.framework without a Team ID. `FORETYPE_SIGN_KEYCHAIN` points both
  scripts at another keychain file.
- On ad-hoc builds, the setup window and Settings ▸ General explain under a permission that
  isn't granted that an entry already on in System Settings belongs to an older build and
  must be removed with − and added again (English and Hindi).

### Localization (2026-10-21)
- The app's interface is localizable and translated into Hindi (हिन्दी): the menu-bar
  menu, every Settings tab, the setup window, Custom Instructions, alerts, the import panel,
  model download messages, tip cards and the Accessibility permission text. English stays
  the base language; macOS picks the language.
- Strings are looked up from the app bundle (`mac/Localization/<lang>.lproj`, copied in by
  `scripts/build-mac.sh`); counts use `.stringsdict` plurals; numbers and percentages
  follow the locale. `scripts/check-localization.py` checks the translations.

### Hands-on fixes and last backlog items (2026-10-21)
- Typo gate and autocorrect: the spell checker now checks in the user's current language
  (with no language it accepted words from any installed language, so "recie" passed), and
  `/usr/share/dict/words` is a second opinion before a fragment counts as a typo (the
  checker's completions missed "vomit").
- Emoji, autocorrect and the typo gate now run before type-through, so a model that
  continues a misspelling no longer carries it past them.
- VS Code's chat input ("Message input") gets suggestions; Cursor and Windsurf too.
- Downloads paused (or running at quit) resume after a relaunch (`--resume-selftest`).
- Settings → Apps: Add an App… changes an app's default without opening it.
- e2e: `scripts/e2e-typing-aids.sh` (TextEdit) and `scripts/e2e-browser-aids.sh` (a
  throwaway Chrome profile).

### Quality and compatibility backlog (2026-10-20)
- Emoji: `:name` offers the emoji (1,913 gemoji shortcodes); Tab replaces the shortcode.
- Autocorrect: a misspelled word just finished gets the macOS spell checker's correction
  as a suggestion (Tab replaces it); names, acronyms and your own words are left alone.
- Typo gate: no suggestion while the word being typed can't become a real word.
- Phrase beam search: 3 beams on mains power (+1.1 points of keystrokes saved), greedy on
  battery.
- Mid-line suggestions (experimental, off by default), in a card under the caret.
- Code editors: VS Code, Cursor and Windsurf chat inputs get suggestions; their editors
  stay off.
- Hints for Google Docs (screen-reader support) and Arc/Dia (Text Metrics); page URLs now
  reach the prompt header; text-marker reads for web editors whose ranges fail.
- Apple on-device model as a no-download backend (macOS 26+, opt-in).
- llama-server receives the personal vocabulary bias (`logit_bias`).
- Import Writing… for personalization from text files.
- `ft-replay --beam`, `--spell`, `--mid-line-eval`; `tools/spell-map`.

### Product (2026-10-20)
- **Settings window** (menu: Settings…, Cmd-,): General (on/off, length, stop at sentence
  end, screen context, custom instructions), Personalization, Apps (the apps you changed,
  with Remove), Model (models, sizes on disk, server) and Statistics tabs. Changes apply at
  once through the same code as the menu, and the menu stays.
- **Statistics:** accepts (Tab and accept-all), words and characters inserted, and
  keystrokes saved (characters minus one key press per accept), today, last 7 days and all
  time, with Reset; "Saved N keystrokes today" in the menu. Counts only, never text; the
  last 30 days plus totals in UserDefaults. `--stats-selftest`.
- **Model manager:** size on disk for each installed model, the Models folder's total, other
  GGUF files in the folder listed and selectable, Delete with a confirmation (the model in
  use is refused), leftover `.part` files shown and deletable. Cancel pauses a download when
  the server allows resuming (Resume, Discard); discarding or quitting deletes the partial
  download from the temporary folder. A failed resume no longer retries with stale resume
  data.
- **Stop at Sentence End** (core `stop_at_sentence_end`, on by default) is now a setting, in
  the Length submenu and the General tab.
- Foretype's windows get Cmd-W, Cmd-Q and the editing shortcuts (cut, copy, paste, select
  all, undo) through a hidden main menu.
- `ftdrive`: lists a submenu, presses toolbar and radio buttons, matches `TITLE*` by prefix,
  and stops after a press that opened a modal alert.
- Download progress reaches the UI in 0.5% steps instead of on every chunk.
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
