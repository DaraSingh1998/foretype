# Foretype reference

The detailed reference for Foretype: how it works, every feature and setting with its
privacy rules and measured numbers, install and update details, per-app behaviour, building,
development tools and known limitations. The product overview is the [README](../README.md).

Free, open-source, on-device inline autocomplete for every app: gray "ghost text" after
your caret, Tab to take the next word, the key above Tab to take all of it. A Cotypist-style
tool built so the engine can be shared across macOS, Windows and Linux.

Status: **phases 1–4 done** (Mac MVP, compatibility, personalization, packaging); macOS
only. Works end to end with a local Qwen3 base model in every app except those off by
default (code editors, password managers, remote desktops, spreadsheets). In Terminal and
iTerm it suggests only on AI-agent prompts (Claude Code, Codex, ...). Releases are published
on GitHub and update themselves.

**Docs:** [Architecture](ARCHITECTURE.md) · [Decisions](DECISIONS.md) ·
[Development](DEVELOPMENT.md) · [Measurements](MEASUREMENTS.md) ·
[Roadmap](ROADMAP.md) · [Releasing](../RELEASING.md) · [Changelog](../CHANGELOG.md) ·
[Research](research/) · [Phase 0 spike](../tools/spike/RESULTS.md) ·
[Claude guidance](../CLAUDE.md)

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
- Only the focused window is read, on whichever display it is, at that display's
  resolution. Other apps' windows (a document or a web page beside the email) are read
  only with **Use text from other apps**, a setting of its own (below).
- It refreshes when a new field gets focus and after a 1.5 s typing pause at most every 15 s,
  never per keystroke, because new screen text changes the prompt header and costs a full
  prefill. The new header is prefilled in the background as soon as OCR finishes.
- Warm OCR takes 145–360 ms (M3 Pro), off the typing path. The very first run on a Mac takes
  much longer while Vision compiles its models.

On a chat-reply sample (`scripts/fixtures/chat-*.txt`), screen context raised keystrokes saved
from 29% to 66% and characters per Tab from 3.2 to 5.2, at the same latency. The reply was
written to refer to the visible messages, so treat this as a best case.

### Text from other apps (opt-in)

With **Use text from other apps** (Settings ▸ Context, or the menu; off by default),
suggestions can quote what other windows show: a document, slides, a spreadsheet or a web
page beside the email you are writing, on any display, and windows you looked at in the
last 10 minutes (decisions D42 and D44).

- **What is read.** Windows on screen on every display (the current Space of each), counted
  as visible when at least a quarter of them is uncovered, and the window you just switched
  away from, covered or not. Each is read through Accessibility: a document's text area (the
  part on screen and some around it), a web page through text markers (the part on screen
  when the browser says where), else the window's texts in order; up to 6,000 characters,
  at most 50 ms per app, on a queue of its own. Where an app gives almost nothing through
  Accessibility, the window is captured and read with Vision's fast OCR, only on Macs with
  12 GB of memory or more, with Screen Recording allowed, and not while saving energy; an
  unchanged window isn't read again. The window you are typing in is never part of it (its
  text is the field and the screen context).
- **When.** When focus moves to another window or app (0.3 s later) and after a 2 s typing
  pause at most every 20 s; never per keystroke.
- **Kept** in memory only, at most 12 windows; a window no longer on screen is kept 10
  minutes after it was last seen. Everything is forgotten when Foretype pauses (also while
  the Mac sleeps, the screen is locked or the display sleeps) and when the setting goes off.
- **Never read**: the never-read list (Settings ▸ Context; password managers to start with:
  1Password, Apple Passwords, Keychain Access, Bitwarden, Dashlane, LastPass, KeePassXC,
  Keeper, Enpass, Strongbox, Proton Pass, NordPass, MacPass, Secrets), apps where you turned
  suggestions off or paused Foretype, Foretype's own windows, windows that forbid capture,
  private browsing windows whose title says so (Incognito, InPrivate, Private Browsing),
  secure fields, and nothing at all while secure input is on. Apps that are off only by
  default (spreadsheets, code editors, terminals) are read: a sheet is what an email quotes.
- **Never with a server**: with a llama-server or OpenAI-compatible backend nothing is read,
  and the core ignores any text it is sent. The Apple on-device model gets it.
- **In the prompt.** The core cuts each window's text into passages of about 300
  characters and, for each prompt, ranks them against what you are writing (BM25 over the
  text before the caret, the last 300 characters counting double, plus the focused window's
  screen text and title); windows on screen outrank recently viewed ones, which need words
  in common with your text. The best passages that fit the budget go first in the prompt,
  under `[Also open: App — Window title]`. The budget is 512 tokens on Macs under 16 GB (the
  engine keeps its 2,048-token context) and 2,048 from 16 GB, where the engine runs with a
  4,096-token context while the setting is on (turning it on or off restarts the built-in
  engine there). The section also leaves room for the rest of the prompt; one that still
  doesn't fit is sent without it. The selection changes only when another one is clearly
  better, since every change costs a full prefill; the new text is prefilled in the
  background as soon as it arrives.
- On the multi-window corpus it saves as much typing as pasting the other window into the
  screen context did (`docs/MEASUREMENTS.md`, "Cross-app context: the real section").

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

### About you

Settings ▸ **About You** holds your own name, email, phone, company, job title, address and
website (one set per macOS account), with a switch for the feature and one per detail.
**Fill from My Card in Contacts…** copies your Contacts card into the empty fields (macOS
asks for Contacts access once, only when you click it).

- **Fill**: when the text before the caret clearly asks for a detail, the ghost text is the
  exact value, tagged "your email": `My email is `, `Call me on `, `I work at `, `Email:` or
  `Phone:` at the start of a line, and your name on the line after a sign-off (`Regards,`,
  `Thanks,`, `Cheers,`, `--`). It only offers a value that matches what you have started
  typing, and is recomputed on every keystroke. One Tab inserts the whole detail, except
  a name, which goes word by word so Tab can take just your first name. No model is
  involved, so it works with every backend.
- **Writer line** (on, with its own switch): with the built-in or Apple model, name, job
  title and company go into the prompt header as `[Written by …]`, so continuations use
  your name. Never sent to a server you configured. On the corpus replay it didn't hurt
  (41.9% → 42.2% keystrokes saved with fills and the writer line, 42.0% with fills alone).
- **Privacy**: stored in `~/Library/Application Support/Foretype/about-you.bin`, sealed with
  ChaCha20-Poly1305 under a key in your login Keychain, never in preferences; nothing leaves
  the Mac. Never filled in secure fields or apps where suggestions are off. Debug logs show
  only which detail was offered, never its value, and mask any piece of your details in
  other logged text (a model suggestion can echo one from the document). **Clear All…**
  deletes the file and key.

### Custom instructions

**Custom Instructions…** in the menu edits a note for all apps (who you are, tone,
spelling) and one for the app you were last in, appended after it. Both go into the prompt
header. The note for all apps starts as a short default ("Natural, clear writing that
matches the tone of the text so far, with correct spelling and grammar."), which saved
0.7 points more typing on the test corpus than no note. Change or clear it; **Restore
Defaults** brings it back.

### Typing aids

- **Emoji**: type a colon and a name (`:tada`, `:+1`) and Tab replaces it with the emoji
  (1,913 GitHub/Slack-style shortcodes).
- **Autocorrect**: after a misspelled word and a space, the ghost shows `→ receive`; Tab
  replaces the word. It uses the macOS spell checker in your languages and leaves names,
  acronyms, words you have written before (in your history, or earlier in the same field)
  and romanized Hindi alone.
- **Typo gate**: no suggestion while the word you are typing can't become a real word. The
  same words pass as for autocorrect.
- **Hindi and Hinglish**: the spell checker knows no romanized Hindi (it offered "hain" →
  "hair" and blocked "jaldi"), so about 470 common Hinglish words and their usual spellings
  (kya, nahi/nahin/nhi, acha/accha, yaar) are never corrected or blocked, and once two of
  the last 40 words in a field are on that list, autocorrect and the typo gate stand down
  for every word there. English typos inside a Hinglish message are then left alone too.
  Devanagari passes the spell checker as it is. A danda (। or ॥) ends a sentence for
  **Stop at end of sentence**, and words with a virama or nukta (क्या, दफ़्तर) stay whole.
- **Phrase beam search**: at full speed the engine weighs 3 candidate phrases instead of
  one (+1.1 points of keystrokes saved on the corpus); greedy while saving energy.
- **Mid-line** (experimental, off): up to three words in a card under the caret when text
  follows it on the line.
- In **VS Code, Cursor and Windsurf** only chat inputs get suggestions; the code editor
  stays off. **Google Docs** and **Arc/Dia** show a one-time tip for the setting they need.

All of these can be turned off in Settings → Typing.

### Pausing and power

**Pause** in the menu stops Foretype for 15 minutes, an hour, until tomorrow (6 in the
morning) or until you resume; **Resume** shows when it would end by itself. Option-click
the menu-bar icon to pause or resume at once. A pause survives quitting, relaunching and
updates. While paused Foretype reads no field, watches no keys, captures nothing and frees
the model's memory (3.3 GB → 70 MB with Gemma 4 E2B; CPU use falls by about 60%, the rest
being a timer thread in llama.cpp's Metal backend, see `docs/MEASUREMENTS.md`); resuming
picks up the field you are in (in
Chrome and Electron apps the first suggestion can take 2 to 3 s while they rebuild their
accessibility tree). **Pause in *app*** stops it in one app for 5 minutes, an hour or until
that app quits (Ctrl+Opt+Cmd + key above Tab: 5 minutes).

Other apps and scripts can pause it too: `open foretype://pause` (until resumed),
`open "foretype://pause?minutes=30"`, `open foretype://resume`, `open foretype://toggle`.

The power rules are in Settings → General:

| When | Choices (default first) |
|---|---|
| On battery | **Save energy**, full speed, pause |
| Battery below | **keep going**, pause below 10%, 20% or 30% |
| Low Power Mode | **Pause**, save energy |
| The Mac runs hot | saves energy when the thermal state is serious, pauses when critical |
| Sleep, a locked screen, display sleep | always paused |

Saving energy: one candidate phrase instead of three, no look-ahead for the next
suggestion, mid-word suggestions wait 80 ms for the next keystroke, no screen context, and
the model is freed after a minute without typing (5 minutes otherwise). The battery rows
are hidden on Macs without a battery. When the power rules pause it, the menu says why
("Paused — Low Power Mode") and offers **Resume Anyway (until plugged in)**; the
menu-bar icon then shows a battery instead of a pause sign.

### Settings window

**Settings…** in the menu (Cmd-, while the menu or one of Foretype's windows is open)
shows every setting in eight tabs; changes apply at once, the same way as from the menu:

- **General**: open at login, pause and resume, the power rules (on battery, low battery,
  Low Power Mode), the version and the update switches with Check Now.
- **Typing**: length (2, 4, 7 or 10 words), stop at the end of a sentence, the typing aids
  (emoji, autocorrect, typo gate, mid-line) and the keys.
- **Context**: screen context, with the Screen Recording status; text from other apps,
  with the never-read list (Add an App…, Remove, Restore Defaults).
- **Personalization**: custom instructions, learn from my writing, strength, what was
  learned, import, delete history.
- **About You**: your own details for exact fills, the writer line, fill from Contacts.
- **Apps**: every app you switched off (or switched on where it is off by default), with
  Remove to return it to its default.
- **Model**: the catalog and every other GGUF in the Models folder, each with its size on
  disk, Use, Download, Cancel, Resume and Delete; the folder's total disk use; the server
  settings.
- **Statistics**: keystrokes saved, words and characters inserted, and suggestions accepted
  (Tab and accept-all), for today, the last 7 days and all time, with Reset.

The window is as tall as the selected tab where the screen has room. Where it hasn't (a
13-inch MacBook Air, a long model or app list), it stops at the screen's edge, clear of the
menu bar and the Dock, and the tab scrolls. Moved to another display, it fits that one.

### Statistics

Every accept adds to the counts: one suggestion accepted, the words and characters it
inserted, and the keystrokes it saved (characters inserted minus the one key press the
accept took). The menu shows "Saved 1,234 keystrokes today · 24,920 in all". Only the
numbers are stored (UserDefaults `usageStats`: totals plus one bucket per day for the last
30 days); never the text, and not the app it went to.

### Languages

Menus, windows and alerts are in **English** and **Hindi (हिन्दी)**. Foretype follows the
language macOS picks for it: System Settings ▸ General ▸ Language & Region (the order of
your preferred languages, or a language just for Foretype under Applications). This is the
interface only; it doesn't change the suggestions. Adding a language is a folder of
translated strings (`docs/DEVELOPMENT.md`).

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

Requirements: Apple silicon (M1 or later), macOS 14 (Sonoma) or later, 8 GB of RAM (16 GB
recommended), and about 1.5 GB of disk for the app and its model.

**One line in Terminal** (recommended):

```bash
curl -fsSL https://github.com/DaraSingh1998/foretype/releases/latest/download/install.sh | bash
```

It downloads the latest DMG, checks its SHA-256, copies Foretype to Applications and opens
it. The [script](../scripts/install.sh) is short; read it first if you like.

**Or the DMG:** download `Foretype-<version>.dmg` from
[Releases](https://github.com/DaraSingh1998/foretype/releases/latest), open it and drag
Foretype to Applications. Foretype is signed with its own certificate rather than an Apple
Developer ID, so the first time you open it macOS says it can't verify the app:

1. Click **Done**.
2. Open **System Settings ▸ Privacy & Security**, scroll down to "Foretype was blocked…" and
   click **Open Anyway**, then confirm with your password or Touch ID.

That's needed once; updates install without asking.

**First launch.** A setup window walks through:

- **Accessibility** (required): lets Foretype read the field you type in and type the words
  you accept. Click Open Settings and switch Foretype on.
- **Screen Recording** (optional): reads text near the field, such as the message you're
  answering. After you switch it on, click **Relaunch**.
- **The language model**: Qwen3 1.7B Base (1.1 GB), downloaded once from Hugging Face and
  checked against a pinned SHA-256.
- **Open Foretype when you log in** (on by default).

Then Foretype lives in the menu bar: a caret with a gray ghost word after it (three dots
while a model loads, an exclamation mark when setup or a permission needs you, a dot in the
corner when an update is waiting). Opened from
Downloads or the DMG, it first offers to move itself into Applications.

**Updates.** Foretype checks GitHub once a day, downloads a new version in the background
and installs it when you've been away from the keyboard for a few minutes, then reopens
with its permissions intact. Settings ▸ General has the switches and Check Now; the menu has
Check for Updates…. With automatic install off, a new version waits for you: the daily
check doesn't open a window over your work, it puts a dot on the menu-bar icon, and the menu
shows **Update Available: X.Y.Z — Install…** and Settings ▸ General **Version X.Y.Z is
available** with an Install button. Both open the update window (release notes, Install,
Skip This Version, Remind Me Later). Skip This Version hides it until you check yourself.

**Uninstall.** Quit Foretype from its menu, drag it from Applications to the Trash, and
optionally delete `~/Library/Application Support/Foretype` (models, encrypted history and
details). Remove it from System Settings ▸ Privacy & Security ▸ Accessibility and Screen
Recording.

**From source:** see [Build](#build).

### Models

The menu's **Model** submenu lists the catalog (`models/catalog.json`, shared by every
shell): Qwen3 base models in three tiers plus Gemma 4 E2B, each pinned to a SHA-256 and
verified after download (interrupted downloads resume; a mismatch is discarded). Keystrokes
saved and latency on the 53-document corpus, M3 Pro (`docs/MEASUREMENTS.md`):

| Model | Size | Picked for | Saved | p50 |
|---|---|---|---:|---:|
| Qwen3 0.6B Base Q8_0 | 0.6 GB | under 12 GB of RAM | 39.9% | 46 ms |
| Qwen3 1.7B Base Q4_K_M | 1.1 GB | 12 GB and up (default) | 41.9% | 73 ms |
| Gemma 4 E2B Q4_K_M | 3.4 GB | opt-in on 16 GB+ | 42.8% | 109 ms |
| Qwen3 4B Base Q4_K_M | 2.5 GB | opt-in on 16 GB+ (about twice the latency) | 45.0% | 147 ms |

**Hindi and Hinglish:** choose Gemma 4 E2B. It saves 34.2% of keystrokes on Hindi
(Devanagari) and 27.7% on Hinglish, against 27.7% and 15.1% for the default Qwen3 1.7B and
32.5% and 23.0% for Qwen3 4B, and it is the fastest of the three on Hindi (p50 125 ms): its
vocabulary spends 1.3 tokens per Devanagari word, Qwen3's 4.6. Below 16 GB, Qwen3 1.7B
beats 0.6B (20.0% and 10.8%).

Installed models show their size on disk, and the submenu shows the Models folder's total.
Other GGUF files in the folder are listed too and can be chosen. **Delete a Model** (and
Delete… in Settings → Model) removes a model file after a confirmation; the model in use
can't be deleted (choose another one first). A download can be cancelled; when the server
allows it, it is paused and resumes where it stopped until Foretype quits. Discarding a
paused download, or quitting, deletes what it had downloaded.

**Use a Server Instead…** points Foretype at your own inference server:

- a llama.cpp `llama-server`: same suggestions as the built-in engine (token healing via a
  GBNF grammar); measured 40.7% keystrokes saved, the same as built-in, at p50 130–147 ms
  over HTTP against 79 ms in-process;
- any OpenAI-compatible completions endpoint (Ollama, LM Studio, a cloud provider): works,
  but with no grammar it completes half-typed words less well (20% saved on the same text).
  An API key, if any, is kept in the Keychain;
- Apple's on-device model (macOS 26+ with Apple Intelligence): nothing to download, but
  about 0.5 s per suggestion and no token healing beyond filtering.

## Build

Requirements: Xcode command-line tools, Rust (`brew install rust cmake`).

```bash
scripts/make-signing-cert.sh  # optional, once: the "Foretype" signing identity, so rebuilds keep their permissions
scripts/build-mac.sh          # build/Foretype.app (FORETYPE_SIGN_IDENTITY, else "Foretype", else ad hoc)
scripts/package-mac.sh        # build/Foretype-<version>.dmg, appcast.xml and cask (see RELEASING.md)
scripts/release.sh X.Y.Z      # tag and push a version; GitHub Actions publishes it
```

`FORETYPE_SPARKLE=1` adds the Sparkle updater (fetched by SwiftPM); see `RELEASING.md` for
signing, notarization and Sparkle keys.

## Run

From source: put a GGUF base model in `~/Library/Application Support/Foretype/Models/` or
set `FORETYPE_MODEL=/path/to/model.gguf`, open `build/Foretype.app` and grant Accessibility
when asked. The menu-bar icon has today's keystrokes saved, Pause (or Resume), suggestion
length, the per-app toggle and pause, personalization, custom instructions, model,
Settings… and setup. Option-click the icon to pause or resume.

| Key | Action |
|---|---|
| Tab | insert the next word |
| key above Tab (` or §) | insert the whole suggestion |
| Esc | dismiss (no new suggestion until you type) |
| Option+Tab | a real Tab |
| Ctrl + key above Tab | suggest here even where Foretype normally stays quiet (this line only) |
| Ctrl+Opt+Cmd + key above Tab | pause suggestions in the current app for 5 minutes |
| Option-click the menu-bar icon | pause or resume everywhere |

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
  of the last few characters and picks the matching font family. In rich-text fields (chat
  composers in Chrome and Electron apps such as Claude or Slack) its caret position skips
  the line breaks between paragraphs that its text has; Foretype lines the two up, so the
  text before and after the caret is right on every line.
- **Apps without usable caret geometry** (Microsoft Teams; LibreOffice, whose paragraph
  positions are off although its character positions are right): Foretype finds the caret
  from pixels, and where the app's character positions turn out to match the screen it uses
  those from then on. When a field gets focus or you pause, it captures the text field a few
  times (never anything else, no image is kept) and looks for the one thin bar that blinks,
  which teaches it the caret's colour and height. While you type it moves the ghost text by
  the width of what you typed and checks the position after short pauses; on a new line, a
  wrapped line or another field of the same app it finds the caret with one capture right
  away (the caret doesn't blink while you type). This uses the Screen Recording permission
  and follows the Screen Context switch; only until an app's caret has been seen once (about
  0.7 s after the first field gets focus) does the suggestion show in a small card above the
  field.
- **Power**: the model is unloaded after 5 idle minutes (1 minute while saving energy;
  about 1 GB freed) and reloaded on the next keystroke; see *Pausing and power* for the
  battery, Low Power Mode and temperature rules.

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
  it whenever you run a dev build on a machine you are also working on. An entry can be a
  pid, to allow one process of an app you also use (a test Chrome next to your own).
- `Foretype --ocr-selftest` renders a fake chat window and checks OCR and row assembly;
  `Foretype --font-selftest` checks the width-based font matcher and the ghost text's font
  from the text before the caret (a soft wrap, mixed sizes, a zoomed document), `Foretype
  --stats-selftest` the statistics counts, day buckets and reset, and `Foretype
  --caret-selftest` the pixel caret detectors on rendered text (no permissions needed).
  `scripts/caret-measure.sh` compares the pixel caret with the Accessibility caret in a test
  document (TextEdit by default) without typing anything.
  `Foretype --download-selftest MODEL_ID` downloads and verifies one catalog model
  (`FORETYPE_MODEL_BASE_URL` and `FORETYPE_MODELS_DIR` point it at a local server and a
  scratch folder).
- CI (`.github/workflows/ci.yml`, manual trigger only for now) runs the unit tests, builds the app, runs the self-tests
  and replays the self-written corpus documents with the 0.6B model on CPU. `ft-replay ... --screen FILE` adds screen text to a replay.
- **Permissions and ad-hoc signing:** macOS ties the Accessibility and Screen Recording
  grants of an ad-hoc-signed `Foretype.app` to that exact build, so after every rebuild the
  entries look on but don't apply until they are removed with − and added again. Run
  `scripts/make-signing-cert.sh` once (it adds a self-signed "Foretype" certificate to
  your login keychain and asks first) and `build-mac.sh` signs with it, so rebuilds keep
  the grants; see `docs/DEVELOPMENT.md`. A bare `mac/.build/release/Foretype` started from
  a terminal uses the terminal's own grant.

## Known limitations (MVP)

- Per-app insertion overrides are in place but every app still defaults to keystrokes;
  entries need testing app by app.
- Live screen capture has been checked in the TextEdit end-to-end test (a development
  build under a parent process with Screen Recording); the bundled app needs its own grant.
- Emoji, autocorrect, the typo gate, the mid-line card and the pixel caret were checked
  live in TextEdit and Chrome (2026-10-21, `docs/MEASUREMENTS.md`). Not yet live: Cursor and
  Windsurf chat labels (VS Code's is checked), text-marker reads, the Google Docs and Arc
  hints, LibreOffice, Mail and Notes.
- The pixel caret (apps without caret geometry) is measured in TextEdit against its
  Accessibility caret, in LibreOffice Writer, in a Chrome chat-composer fixture (also on
  a display above the main one), in the Claude app and in WhatsApp Web in full-screen
  Chrome; it is untested in Microsoft Teams, Obsidian and Slack. A
  caret that never blinks (the "prefer non-blinking cursor" Accessibility setting) is never
  found, and an app's first field shows the card above the field for about 0.7 s first. LibreOffice Writer reported no focused text element for a document opened
  from outside (no clicks or typing were possible in the test), so suggestions there are
  unverified.
- The setup window, the menu and the Custom Instructions window have been checked by
  screenshot (`ftdrive`, 2026-10-20), not by an automated test; saving instructions and the
  personalization submenu were not exercised. The recorder, history and bias are covered by
  unit tests and replays.
- The Settings window's tabs (five then; the eight of today are checked by
  `Foretype --settings-selftest` and by eye on 2026-10-23), deleting a model (and the refusal for the one in use),
  removing an app, resetting statistics, and cancel/resume/discard of a download (from a
  local test server) were checked by screenshot (`ftdrive`, 2026-10-20). Cmd-, and the
  editing shortcuts in Foretype's windows, personalization on/off and the server fields'
  Apply were not exercised there (they would type keystrokes, create a Keychain item or
  start an engine).
- Sparkle updates work end to end with a local feed and a throwaway key
  (`scripts/sparkle-local-test.sh`): the silent install, and with automatic install off the
  menu line, the Settings line and the icon's dot (read back from the app's own report, not
  from a click on the real menu). Notarization and a real feed still need a Developer ID
  certificate, notary credentials and Sparkle keys (`RELEASING.md`). The release workflow
  is an untested template.
- Text from other apps is checked end to end only in TextEdit (`scripts/e2e-context.sh`,
  Accessibility text) and by `--context-selftest` (the pool's rules, fast OCR of a rendered
  window); reading browsers through text markers, Word, Keynote, Preview and Electron apps,
  and the OCR fallback on a live window are untested, as is the Settings ▸ Context never-read
  list beyond rendering.
- The setup window, Model menu and server dialog have not been exercised in the automated
  tests; the downloader is covered by `--download-selftest` and the server backends by
  replays against a local llama-server.

## Licensing

Core and shell: MIT OR Apache-2.0. `compat/apps.json`: CC0-1.0. The catalog models (Qwen3
base, Gemma 4 E2B) are Apache-2.0 and are not bundled. Third-party code and data (llama.cpp,
Sparkle, gemoji, Rust crates, oasst1 excerpts) are listed in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), which ships in the app with the licence
texts.
