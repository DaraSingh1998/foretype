# Changelog

Each `## X.Y.Z` section is a release: `scripts/release.sh` turns `## Unreleased` into one, and
the release notes are taken from it.

## Unreleased

## 0.1.6 (2026-10-23)

### Text from other apps no longer holds up typing (2026-10-23)
- When the text Foretype uses from other windows or from the screen changes, your next
  suggestion no longer waits while the model reads it: suggestions keep coming from what it
  had, and the new text is read in the background between keystrokes and used as soon as
  it is ready. With the default model and a full section of other apps' text, the first
  suggestion after such a change comes in about 0.1 s instead of about 1 s.
- Returning to a field you were writing in no longer makes the model read its context
  again: recent ones are kept in memory for up to 10 minutes (on Macs with 12 GB or more),
  and forgotten with the rest of other apps' text when Foretype pauses, the screen locks or
  the Mac sleeps.
- While Use Text from Other Apps is on, the model's memory for its context takes half the
  space, so Macs under 16 GB now get the same larger context as bigger Macs, at the memory
  the smaller one used. Turning the setting on or off restarts the model on every Mac.
- Reading other windows with OCR (Macs with 12 GB or more) does less work: at most 0.4 s
  per refresh, and a window read in the last minute isn't captured again after a typing
  pause.

## 0.1.5 (2026-10-23)

### Switching models no longer stops suggestions (2026-10-23)
- Choosing another model in Settings ▸ Model, or turning Use Text from Other Apps on or off
  on a Mac with 16 GB or more (which restarts the model with a larger context), could stop
  suggestions with "backend init: BackendAlreadyInitialized" in the menu, because the new
  model started loading before the old one was freed. The engine now shares one llama.cpp
  backend, and the new model waits for the old one to be freed, so two models are never in
  memory at once.

### Text from other apps (opt-in) (2026-10-23)
- New setting, off by default: **Use text from other apps** (Settings ▸ Context, and in the
  menu). Suggestions can then use what other windows show, on any display: the document,
  spreadsheet, slides or web page beside the email you are writing, and windows you looked
  at in the last 10 minutes. Text is read through Accessibility, and on Macs with 12 GB of
  memory or more also with on-device OCR where an app shares no text.
- Kept in memory only and forgotten when Foretype pauses, the screen locks or the Mac
  sleeps. Never used with a server backend. Password managers are never read; the list is in
  Settings ▸ Context, where you can add any app. Apps where you turned Foretype off, private
  browsing windows and password fields are never read either.
- Only the passages that match what you are writing go into the suggestion's context, up to
  about 2,000 characters on Macs under 16 GB (more from 16 GB, where turning the setting on
  restarts the model with a larger context). On a test set written to quote another window,
  the default model saves 61% of keystrokes with it and 42% without (screen context on).
- Suggestions no longer echo the prompt's own section markers (`[End of screen t…`).

### A Keychain that says no no longer costs your writing history (2026-10-23)
- Data safety: when Foretype couldn't read the key of your writing history from the
  Keychain (you clicked Deny on a Keychain prompt, the keychain was locked, or the app's
  signature had changed), it took that as "no key yet", made a new one and replaced the old
  key, so the history written until then could never be read again. The same could happen
  to your About You details. Now a new key is made only when the Keychain has none and
  there is no history or details file it could open. Any other failed read leaves the key
  and the file alone: the history (or the details) is **locked** for that run, nothing is
  learned, opened or deleted, and the Personalization menu and Settings say "Writing
  history is locked" with **Try Again**. Settings ▸ About You shows the same for your
  details, with Try Again; Clear All still deletes them.
- Keychain writes update the item in place instead of deleting it and adding it again, so
  a write that fails can't leave no key at all.
- The server API key gets the same care. A Keychain read that fails no longer counts as
  "no key": the engine goes without a key for that run, the server fields say "Saved API
  key can't be read; type to replace" instead of "optional", and the saved key is left
  exactly as it is unless you type a new one (an empty field never deletes it). After a
  denied or cancelled prompt, refreshing Settings no longer asks the Keychain again, and a
  new key the Keychain refuses to store now says so instead of failing silently.
- A writing history that doesn't open with the key in your Keychain is no longer written
  to. Before, Foretype read nothing from it but kept adding to the same file, and its next
  clean-up rewrote the file without the old entries, so the right key could never read them
  again. Now such a history is locked and kept exactly as it is: nothing is learned or
  imported, and the Personalization menu and Settings say "Writing history is locked" with
  a note that the key doesn't open it. Delete Writing History… starts a new one.

### Settings fit the screen (2026-10-23)
- Settings ▸ General had grown taller than a MacBook screen: the update switches and Check
  Now ran behind the Dock and couldn't be reached. Its settings are now in three tabs:
  **General** (open at login, pause, the power rules, version and updates), **Typing**
  (length, stop at the end of a sentence, emoji, spelling fixes, mid-line, the keys) and
  **Context** (screen context). Custom instructions moved to **Personalization**.
- The Settings window never grows past the screen it is on: a tab taller than the space
  between the menu bar and the Dock scrolls, and the window stays on screen when you switch
  tabs or move it to another display. The Apps list is as tall as the apps in it.

## 0.1.4 (2026-10-23)

### Whole first suggestions after a long context (2026-10-23)
- The first suggestion after a lot of new text (a long screen context, a long document
  before the caret) often stopped after one word: its 300 ms time limit started while the
  GPU was still reading the end of the text. The limit now starts once the text is read.
  With Qwen3-1.7B and 1,800 tokens of context, 15 of 21 first suggestions were cut short
  before and none now, in about the same total time (`docs/MEASUREMENTS.md`). Typing
  otherwise is unchanged (41.9% of keystrokes saved on the corpus, before and after).

### Full-screen windows and several displays (2026-10-23)
- In a window in full screen (its own Space), such as WhatsApp Web in full-screen Chrome,
  suggestions showed in a card (⇥ …) instead of after the caret. macOS refuses to capture a
  full-screen window on its own, so where the app gives no caret position Foretype never
  found the caret. Such a window is now captured through its display with only that window
  in the picture: in WhatsApp Web every suggestion is drawn inline. Screen context reads
  full-screen windows the same way.
- Screen context now captures a window at its own display's resolution. A window on a
  display above or below the main one, or on a standard external display next to a Retina
  one, could be captured at the wrong scale: larger than needed (slower text recognition) or
  smaller (text read less reliably), because the window's position was compared with the
  displays' in two different coordinate systems.
- The suggestion card above a field (in apps that report no caret position) and the tip
  cards went below the field whenever the field was on a display above the main one, and a
  card for a field at the top of a display below the main one could appear on the main
  display. Both now stay on the field's display.
- Screen context could read the wrong window after the window you type in was moved (for
  example dragged to another display): it looked for the window where it was when the
  field got focus, and found another window of the same app there. It now reads the window
  that holds the field, and nothing when none does; the window's position is read again
  when the field moves.
- `Foretype --geometry-selftest` checks the coordinate conversions on made-up layouts with
  displays left of, above, below and right of the main one, at 1x and 2x.
- `FORETYPE_DEBUG` logs where the ghost panel is on screen (`show=inline at X,Y`) and which
  window screen context captured, at what scale.
- `FORETYPE_DEBUG` says why a blink search found no caret (no capture, or what changed
  between frames); `scripts/e2e-inline-caret.sh` takes `WINDOW_POS` to open its window on
  another display.

### Whole first suggestions after a long prompt (2026-10-23)
- The first suggestion after a long prompt (a new field with a lot of text on screen, or
  after the screen text changed) often stopped after one or two words: the 300 ms limit for
  generating it started while the GPU was still reading the end of the prompt. The limit now
  starts once the prompt is read, so that suggestion is as long as the others, in about the
  same time (Qwen3-1.7B with a full 2,048-token prompt: 15 of 21 cut short before, none now;
  `docs/MEASUREMENTS.md`).

### Measuring context from other apps (2026-10-23)
- `eval/corpus-multiwindow.jsonl`: 21 replies and notes written while another app shows
  what they quote (a budget in Word, a launch plan in Keynote, a pricing page, a quote in
  Preview). `ft-replay --context-mode none|focused|other|both` replays them with no screen
  text, the focused window's, the other app's or both; `--ctx-bench` measures the first
  suggestion (its prefill, generation, words and whether the time limit cut it), typing
  latency and memory with a full context window, and `--n-ctx`
  sets its size. `scripts/bench-context.sh` runs it all for every installed model. The
  baseline is in `docs/MEASUREMENTS.md`; the plan is in `docs/ROADMAP.md` (D42).

## 0.1.3 (2026-10-23)

### Ghost text at the right size (2026-10-22)
- In a short or narrow window, ghost text could be drawn several times too big (about 60 pt
  next to 20 pt text in TextEdit): when the last 24 characters before the caret crossed a
  soft wrap, their on-screen width was the whole line's, which read as a zoomed document.
  The width is now measured only on the caret's visual line.
- Ghost text follows the size you are typing in. Text typed at 12 pt after 20 pt text got
  20 pt ghost text: the font was read once per line, before typing, and the zoom check
  measured both sizes together. The font is now read again for the first few characters
  typed after the caret arrives (and after a click, an arrow or a deletion), and the check
  measures only the characters in the caret's font, after the last newline or tab.
- `FORETYPE_DEBUG` logs the font each suggestion is drawn in; `--font-selftest` checks the
  ghost font for a soft wrap, mixed sizes and a zoomed document.

### Hindi and Hinglish (2026-10-22)
- Autocorrect and the typo gate leave romanized Hindi alone. The macOS spell checker knows
  none of it, so it offered "hain" → "hair", "mein" → "main" and "tum" → "sum", and hid
  suggestions while typing "jaldi" or "matlab". About 470 common Hinglish words (with their
  usual spellings: nahi/nahin/nhi, acha/accha) are now never corrected or blocked, and in a
  field where two of the last 40 words are Hinglish, neither aid fires at all.
- A word typed earlier in the same field and kept is no longer corrected or blocked again
  (names, jargon, any language).
- The Hindi danda (। and ॥) ends a sentence: **Stop at end of sentence** stops there, and a
  capitalized word after it counts as a sentence start.
- Hindi words with a virama or nukta (क्या, दफ़्तर) are no longer split in two, which made
  the prompt end in half a syllable and kept them out of Learn From My Writing whole.

## 0.1.2 (2026-10-22)

### A waiting update is visible (2026-10-22)
- With "Install updates automatically" off, a new version no longer shows only as Sparkle's
  window from the daily check. The menu-bar menu shows **Update Available: X.Y.Z —
  Install…** near the top and Settings ▸ General shows **Version X.Y.Z is available** with
  an **Install…** button; both open the update window (release notes, Install, Skip This
  Version, Remind Me Later). The offer stays after Remind Me Later and across relaunches,
  until the update is installed or a check finds none.
- The daily check no longer opens that window over your work, even in the background: it
  puts a dot on the menu-bar icon (Sparkle's gentle reminders) until you open the window.
- Skip This Version hides the offer; Check for Updates… still shows a skipped version.
- `scripts/sparkle-local-test.sh` checks the menu line, the Settings line, the dot and the
  window the line opens before the silent install (`FORETYPE_UPDATE_REPORT`).

### Pause, and power-aware pausing (2026-10-22)
- **Pause** replaces the Suggestions On switch: for 15 minutes, 1 hour, until tomorrow
  (6:00) or until you resume, from the menu, Settings ▸ General, an Option-click on the
  menu-bar icon, or `foretype://pause`, `foretype://pause?minutes=N`, `foretype://resume`,
  `foretype://toggle`. The menu shows why and until when ("Resume (paused until 3:45 PM)").
  A pause survives quitting and updates; a switched-off Suggestions On becomes "paused until
  I resume".
- Paused means none of Foretype's own work runs: no field reads (the 0.5 s poll and the
  Accessibility observers stop), no key taps, no screen captures, the Chrome/Electron
  accessibility flags are put back, and the model is freed at once (3.3 GB → 70 MB with
  Gemma 4 E2B). Resuming reads the field you are in again. llama.cpp's Metal residency
  heartbeat still runs (see `docs/MEASUREMENTS.md`).
- Power rules in Settings ▸ General: on battery save energy (default), run at full speed or
  pause; in Low Power Mode pause (default) or save energy; optionally pause below 10, 20 or
  30% battery. A hot Mac saves energy, a critical one pauses. Sleep, a locked screen and
  display sleep always pause. Paused by a power rule, the menu says why and offers Resume
  Anyway (until plugged in), and the menu-bar icon shows a battery. Battery rows are hidden
  on Macs without one.
- Saving energy now also turns screen context off and frees the model after a minute
  without typing (besides greedy decoding, no prefetch and the 80 ms mid-word wait).
- **Pause in *app*** in the menu: 5 minutes, 1 hour or until the app quits (the
  Ctrl-Option-Command hotkey still pauses for 5 minutes).
- Power and session changes come from system notifications; the 30 s power poll is gone.
- Core: a `paused` setting drops queued work, cancels a running completion, frees the model
  and reports `status: paused`; `submit` answers `paused`, `warm` does nothing.

## 0.1.1 (2026-10-22)

### App icon and menu-bar glyph (2026-10-22)
- Foretype has an app icon: a white caret with a gray ghost word after it on a dark ink
  tile, drawn by `scripts/make-icon.swift` into `mac/Resources/AppIcon.icns`. Finder, the
  Dock, alerts, System Settings' privacy lists and the update dialog show it instead of a
  generic icon, and the DMG uses it as its volume icon. It follows Apple's icon template, so
  macOS 26 and later fit it to their own shape instead of boxing it in a gray tile.
- The menu-bar icon is the same caret and ghost word, drawn in code (replacing the
  `text.cursor` symbol), and shows the engine's state: three dots while starting or loading
  a model, an exclamation mark when setup, a permission or an error needs attention.
  Glyphs for paused and paused-to-save-power are ready for a pause feature
  (`MenuBarIcon.set(.paused)`).

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

### Default custom instructions (2026-10-22)
- Custom instructions start with a note for every app: "Natural, clear writing that matches
  the tone of the text so far, with correct spelling and grammar." On the test corpus it
  saved 0.7 points more typing (42.8% → 43.5%, Gemma 4 E2B) and made Apple's model guess the
  next word right more often (17.0% → 19.8%). Change or clear it in Custom Instructions;
  **Restore Defaults** brings it back, and Settings marks it "Default" while untouched.
- The defaults are in `core/data/default-instructions.json` (`ft_default_instructions`), and
  `ft-replay --default-instructions` / `--instructions FILE` replays with them.

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
