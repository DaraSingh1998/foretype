# Decision log

Each entry: what was decided, why, and what it costs. Newest last. Evidence lives in
`docs/MEASUREMENTS.md`, `docs/research/cotypist-report.md` and `tools/spike/RESULTS.md`.

## D1. Portable Rust core behind native shells (2026-10-19)

**Decision.** Put prompt building, inference, the policy gate, suggestion reuse and
personalization in a Rust crate with a C ABI; keep each OS surface native (Swift/AppKit on
macOS; later Rust + UI Automation/TSF on Windows, an Fcitx5/IBus addon on Linux).
**Why.** Every existing open-source Cotypist clone (about 20) is Swift-only, which strands
the hard algorithmic work on one OS. No open-source project ships LLM ghost text on all
three platforms. Rust's llama.cpp bindings (`llama-cpp-2`) are actively maintained.
**Cost.** An FFI boundary (JSON strings) and two toolchains. macOS Accessibility stays in
Swift, because Rust's macOS AX bindings are thin.

## D2. Licensing: MIT OR Apache-2.0; compatibility data CC0

**Why.** The largest clone (Cotabby) is AGPL, so a permissive project at community scale is
the open gap. Apache-2.0 adds a patent grant; MIT/Apache code can flow into GPL/AGPL
projects. The per-app compatibility database is CC0 so every clone can share one commons.
**Rule.** Never copy Cotabby (AGPL) code. Re-implement documented findings. Ideas from
MIT-licensed Tabber and KeyType were used as references.

## D3. Start fresh rather than fork

**Why.** Forking KeyType means a Swift-only architecture; forking Cotabby means AGPL and
macOS lock-in. A new repo with a portable core was the only route to D1 and D2.

## D4. In-process llama.cpp as the default runtime

**Alternatives.** MLX (faster decode in some reports, weaker prefill and prefix-cache
control), Ollama as a dependency (about half llama.cpp's throughput in one M4 Max
measurement), Apple Foundation Models (20–30 tok/s, 4,096-token context, rate-limited in
the background on battery, no raw continuation).
**Why.** Direct control of the KV cache is what makes keystroke-rate completion possible
(D7). llama.cpp is MIT, runs on Metal, and is statically linked (no
`disable-library-validation` entitlement needed).

## D5. Qwen3 base (non-instruct) models, dense only, tiered by RAM

**Why.** Base models used as plain text continuers. Qwen3 0.6B/1.7B/4B Base are Apache-2.0
and dense full-attention, so the KV cache can be truncated to any prefix. Gemma 4
(sliding-window) and Qwen3.5 (recurrent layers) need state snapshots first. TabType found
an off-the-shelf Qwen3-4B base saved more characters than Cotypist's own model file: the
model is not the moat.
**Tiers.** 0.6B Q8_0 below 12 GB of RAM (small models degrade under heavy quantization),
1.7B Q4_K_M as the default, 4B Q4_K_M opt-in on 16 GB+ (about twice the latency; 7-word
suggestions break the 250 ms budget).

## D6. Prompt ends before the partial word; token healing completes it

**Why.** BPE vocabularies attach a space to the following word, so a prompt ending mid-word
or in a space makes base models stumble. Cutting before the fragment keeps the prompt
prefix byte-identical for the whole word (KV cache stays warm), and masking the first
decode steps to tokens consistent with the typed letters lets the model complete any
partial word. Token healing does most of the work: most accepts complete a word after 1–3
typed letters.

## D7. KV prefix reuse and rollback; no fixed debounce

**Decision.** Keep the longest common token prefix, prefill only the tail, roll generated
tokens back after each suggestion. Every keystroke cancels in-flight work between decode
steps; there is no fixed debounce on mains power.
**Evidence.** 1 token prefilled per keystroke (p50); time to first token 12–25 ms warm on
an M3 Pro; full suggestions p50 60–85 ms with 1.7B. On battery, an 80 ms mid-word debounce
saves energy (word boundaries still fire immediately).

## D8. Accessibility + overlay on macOS (not Input Method Kit)

**Why.** An input method gives native commit but the host app styles marked text
(underlined, not gray), it conflicts with CJK input methods, and users must switch input
sources. Cotypist and every clone use Accessibility plus an overlay. Windows (TSF) and Linux
(Fcitx5/IBus) will use input-method frameworks, where preedit ghost text is the norm; that's
why the core emits state, not pixels.

## D9. Two event taps

A permanent listen-only tap (cannot stall input) plus a consuming tap enabled only while a
suggestion is visible (Cotabby found an always-active consuming tap stalled other apps).
Accessibility alone was enough for both on macOS 27 (no Input Monitoring prompt).

## D10. Insertion: Unicode keystrokes by default; paste only when the clipboard can be restored

Keystrokes look like typing to the host (undo, styling, web input events behave). Paste is
per-app (`compat/apps.json`) and only used when `NSPasteboard.accessBehavior` is "always
allow", because reading the clipboard to restore it otherwise raises a permission alert;
without it Foretype types instead of leaving the user's clipboard overwritten.

## D11. Caret: prefer the previous character's trailing edge

Phase 0 measured the zero-length `AXBoundsForRange` one line too high in every TextKit app
(TextEdit, Notes, Stickies, Safari's address bar). Both rects are read; disagreement by a
line teaches a per-app offset used at line starts. Teams and LibreOffice expose no usable
geometry; the pixel caret locator (D31) places the ghost text there.

## D12. Default policy: quiet where Tab matters

Off by default in code editors, password managers, remote desktops, VMs and spreadsheets;
in small single-line fields (< 260 pt) and search fields; with more than 8 characters after
the caret on the line. Terminals are on only for AI-agent prompt lines (Claude Code,
Codex, …), matching Cotypist. The user can force a line (Ctrl + key above Tab) or enable an
app.

## D13. Screen context on by default once permitted (user request, 2026-10-19)

The blueprint had it as an opt-in Phase 3 feature; the user asked for it as a core
capability, as in Cotypist. It refreshes only on focus and typing pauses (≤ every 15 s)
because new screen text changes the prompt header and costs a full prefill; the new header
is prefilled in the background. On a chat-reply sample it raised keystrokes saved from 29%
to 66%.

## D14. Personalization: opt-in, encrypted, no fine-tuning

Matches Cotypist's observable behaviour: only fields where a suggestion was accepted, only
typed text ≥ 20 characters, encrypted with a key in the Keychain, deletable, effect undone
immediately. Implemented as a decode-time vocabulary bias plus up to two same-app examples
in the prompt header. Measured gain is small (41.0% → 41.6% keystrokes saved on the
self-written corpus, mostly from the examples); Strong over-steers (41.3%). Default
strength Balanced.

## D15. Prefetch on mains power only

Computing the suggestion that follows the shown one makes the next one instant after an
accept-all (about 6% of suggestions with a 150 ms reaction time) at no measured latency
cost, but roughly doubles generated tokens, so it's off on battery.

## D16. Bring-your-own server backends

`llama-server` gets a GBNF grammar for token healing and matches the built-in engine's
savings (40.7%), at higher latency (p50 ~130–147 ms over HTTP). OpenAI-compatible
endpoints have no grammar or logits, so healing is approximated (filter + fallback request)
and saves about half as much (20%). Documented in the UI so users can choose.

## D17. Distribution: unsandboxed, notarized DMG + Sparkle (opt-in build) + Homebrew cask

Cross-app Accessibility control and global event taps rule out the App Store sandbox.
Sparkle is only linked in release builds (`FORETYPE_SPARKLE=1`, pinned to 2.10.0 in
`Package.swift`, because `Package.resolved` disappears whenever the dependency-free default
build runs). Notarization needs a Developer ID; none exists on the developer Mac yet.

## D18. CI is manual-only

macOS runner minutes are billed at 10× on a private repo. `ci.yml` runs on
`workflow_dispatch` only. Restore push triggers only when the user asks. (2026-10-22: the
repository is public, so minutes are free; the triggers stay manual until asked.)

## D19. Development safety on a shared Mac

After an unrestricted dev run briefly suggested in a messaging app the user had open: all dev and test runs
use `FORETYPE_ONLY_APPS`; e2e tests wait for user idle, pause or abort when focus leaves,
type only into new documents they created, and never press Send. The terminal test uses a
`.command` window running `tee` so nothing reaches a shell and no AppleScript consent is
needed.

## D20. Model catalog in the core, downloads in the shell

The catalog (`models/catalog.json`, pinned SHA-256 and sizes) is compiled into the core so
every shell shares it; downloading, resuming and verifying use platform networking
(URLSession on macOS). A download is moved into place only after it verifies.

## D21. Cache rollback per architecture: full SWA cache, recurrent snapshots (2026-10-19)

**Decision.** Sliding-window models (Gemma 4) run with a full-size SWA cache so the normal
truncate-to-prefix path works; recurrent and hybrid models (Qwen3.5) snapshot their
recurrent state before each prompt's last token and restore it to roll back.
**Why.** Both keep the one-sequence, prefix-reuse design (D7) and its 1-token prefill per
keystroke. llama.cpp's own per-token recurrent rollback (`n_rs_seq`) is experimental,
single-use and sized for speculative decoding; explicit snapshots cover backspaces and
prefetch. The full SWA cache costs only the window's difference at a 2,048-token context.
**Cost.** A snapshot copy (about 20 MB for Qwen3.5 0.8B) once per new prompt prefix, i.e.
per word, and up to 4 snapshots in memory (80.8 MB measured). Verified with `ft-replay --check-cache` (`docs/MEASUREMENTS.md`).

## D22. macOS only for now (user decision, 2026-10-19)

**Decision.** Phases 5 (Windows shell) and 6 (Linux shell) are deferred; work goes into the
macOS app and the core.
**Why.** The user wants Foretype for macOS only.
**Cost.** None today. The core keeps its portability rule (no Mac-only APIs in `core/`), so
the Windows and Linux plans in `docs/ROADMAP.md` stay valid if the decision changes.

## D23. Chromium: keep `AXEnhancedUserInterface` set (2026-10-20)

**Decision.** FocusTracker sets `AXEnhancedUserInterface` on a Chromium app once per process
and keeps it until Foretype quits, checking it 0.5 s after the set and while the app shows no
focused element, and setting it again only when it reads `false`.
**Why.** It is the only outside trigger that makes a fresh Chrome expose its web content
(`docs/MEASUREMENTS.md`): an AXObserver, walking or hit-testing the tree, focus changes in
the page and `AXManualAccessibility` do nothing. Chrome debounces the flag for 2 s and drops
the request if it is cleared in that window, so it can't be pulsed, and setting it again
while set restarts the wait. `--force-renderer-accessibility` works at once but needs
Foretype to launch Chrome.
**Cost.** About 2 s (3 s when Chrome clears the flag as it activates) before a fresh Chrome
gets suggestions; the flag stays on while Foretype runs, which some window managers dislike
(restored on quit, and never set while VoiceOver runs).

## D24. Settings window beside the menu; statistics are counts only (2026-10-20)

**Decision.** A Settings window (AppKit, toolbar tabs) is a second surface for every
setting; the menu keeps its items. Both call the same `AppDelegate` methods
(`PreferencesHost`). Statistics count accepts, words, characters and keystrokes saved
(characters inserted minus one key press per accept) per local day for 30 days and in
total; they store no text and no app names.
**Why.** The menu was getting long, and some things (the per-app list, model files, disk
use, statistics) don't fit in a menu. One code path keeps the two from drifting. Keystrokes
saved uses `ft-replay`'s definition (accepted characters minus accept key presses), so the
app's number and the measurements agree; per-app counts would say where someone writes and
gain little.
**Cost.** Keystrokes saved is an estimate: it assumes one key press per character the user
would otherwise have typed (no autocorrect or shortcuts), and counts an insertion even if
the host app dropped it.
**Update (2026-10-23).** General had grown taller than a MacBook screen: on a 14-inch
MacBook Pro its update rows ran behind the Dock, out of reach. It is split into General
(login, pause, power, version and updates), Typing (length, sentence end, typing aids,
keys) and Context (screen context; text from other apps joins it), and Instructions moved
to Personalization: eight tabs, which still fit the 580 pt toolbar in English and Hindi.
Every pane also scrolls inside a window capped at its screen's visible frame, so a tall
pane (a long model list, a new setting) can never run off screen again. Fewer, longer tabs
would have meant scrolling on every Mac; more tabs would not fit the toolbar.

## D25. Spelling: the platform's spell checker decides, the core applies the policy (2026-10-20)

**Decision.** The shell asks `NSSpellChecker` (off the main thread, in the user's own
languages and learned words) whether the partial word can still become a word and whether
the word just finished is misspelled; the core turns that into the typo gate and
autocorrect, with leniency for capitals, acronyms, digits and the user's own words.
**Why.** The Phase 0 gate used `/usr/share/dict/web2` and falsely blocked names, British
spellings and brands; the system checker knows them and costs under a millisecond. Keeping
the policy in the core keeps it portable (another shell can plug in Hunspell).
**Cost.** The replay tool can't call the checker, so `tools/spell-map` precomputes verdicts
for a corpus. On the clean corpus: 4 false blocks, no change in keystrokes saved. Romanized
Hindi, which no system dictionary knows, is handled by the core's own word list (D41).

## D26. Replacement suggestions for emoji and autocorrect (2026-10-20)

**Decision.** A suggestion may replace text before the caret (`replace` in the event and in
`accept`); the shell deletes it with Backspace and inserts the new text. Replacements are
accepted whole, never typed through or cached, and not counted as typing saved.
**Why.** Both features change what was typed rather than extend it; one mechanism serves
both, and other shells can implement it the same way (TSF and IBus can delete surrounding
text).

## D27. Mid-line by plain continuation, off by default (2026-10-20)

**Decision.** Mid-line suggestions use the normal prompt, at most 3 words, cut where they
repeat the rest of the line, shown as a card under the caret; the setting is off by default.
**Why.** Fill-in-the-middle with Qwen3's FIM tokens got 5.6% of words right against 72.1%
for plain continuation (`docs/MEASUREMENTS.md`). Inline ghost text would overlap the rest of
the line. Cotypist keeps mid-line in Labs too.

## D28. 3-beam phrase search on mains power (2026-10-20)

**Decision.** Beam width 3 when on mains power, greedy on battery.
**Why.** +1.1 points of keystrokes saved for +16 ms p50 and +15% GPU energy; wider beams
did worse (they favour probable phrases over the right next word). Beams live in extra KV
sequences, so prefix reuse and rollback are unaffected; recurrent models stay greedy.

## D29. Apple Foundation Models as an opt-in shell backend (2026-10-20)

**Decision.** The core gains a `shell` backend that calls a completer the shell installs;
on macOS it is Apple's on-device model, offered only where Apple Intelligence is available
and never chosen automatically.
**Why.** The research plan called for a zero-download fallback. The model is a chat model
(no raw continuation, no logits): about 0.5 s per suggestion warm, no token healing beyond
the OpenAI-style filter. FoundationModels is weak-linked so the app still runs on macOS 14
and 15.

## D30. No Cotypist history import (2026-10-20)

**Decision.** Instead of importing Cotypist's history, Import Writing… takes text files the
user picks.
**Why.** Cotypist's `cotypist.db` is encrypted (not a SQLite header) with a key in
Cotypist's own Keychain item; reading it would mean breaking another app's encryption.

## D31. Pixel caret locator as the fallback (2026-10-20)

**Decision.** When `CaretResolver` finds no caret in a text field with text, or the app's
rule says `"caret": "pixel"`, find the caret from pixels of the app's own window: a blink
detector (several captures of the field at a typing pause; the caret is the one thin bar
that toggles) and a verify detector (one capture near the predicted position, a bar of the
colour and height the blink detector learned). Between captures, advance the last position
by the rendered width of the text typed on the same line. Only at pauses, never per
keystroke; only the field's rectangle; images dropped after the search. When AX did report
a character rect that only the field-frame check rejected, the locator confirms it: two
matches and that app's rects are used again (LibreOffice: paragraph frames 98 pt off,
character rects right to 0.5 pt), so the captures stop.
**Why.** Teams, LibreOffice and Obsidian/CodeMirror give no usable caret geometry
(D11), so the ghost text could only sit in a mirror card above the field. The blink is the
one signal that tells a caret from a glyph stem without knowing the font: in TextEdit,
where AX is right, the blink detector matched the AX caret to 0.00 pt at 12 of 12 positions
(`docs/MEASUREMENTS.md`). Text-marker APIs (`AXBoundsForTextMarkerRange`) would cover
Chromium and Electron only, not LibreOffice's own toolkit, and Teams can't be tested on the
developer Mac.
**Cost.** Uses the Screen Recording permission, so it follows the Screen Context switch.
A new field or a new line shows the mirror card until the caret first blinks off (about
0.7 s; up to 1.3 s). Each pause in such an app costs 1–11 captures of about 45 ms each on a
background queue. Between checks the ghost text follows the host font, or a guessed font
times a learned width scale (about 1 pt off over a line). A caret that does not blink (the
Accessibility "prefer non-blinking cursor" setting, or an app that never blinks) is never
found: the mirror card stays. Soft-wrapped lines are found again only at the next pause.
(D37 adds a one-capture search while typing for new fields, lines and wraps.)

## D32. Stay on llama.cpp after an MLX comparison (2026-10-21)

**Decision.** Keep the in-process llama.cpp engine (D4); MLX stays an experiment.
**Why.** On the same Mac and model size MLX decoded 5% faster and prefilled 12% slower
(`docs/MEASUREMENTS.md`), and its keystroke loop was no faster than the engine's. Switching
would trade the portable Rust core, GGUF models and the KV rollback work (D21) for an
Apple-only runtime with no measurable gain.


## D33. Localization: English keys, `.lproj` folders copied into the bundle (2026-10-21)

**Decision.** Every UI string is `L("English text")`, looked up in `Bundle.main`, with the
English text as key and fallback. Translations are hand-kept `.strings`/`.stringsdict`
files in `mac/Localization/<lang>.lproj`, which `scripts/build-mac.sh` copies into
`Contents/Resources`. Hindi is the first language besides English.
**Why.** A SwiftPM `resources:` target puts its bundle at the `.app`'s top level, which
code signing rejects, and `Bundle.module` would look for it there. Copying `.lproj`
folders is what Xcode does and needs nothing at run time. English keys keep the code
readable and make a bare dev binary (no `.lproj`) fall back to English with no extra step.
Numbers are formatted before they reach a format string, so translations only move
`%n$@` placeholders; plurals use `.stringsdict` so a language with more forms than English
only needs its own file. Hindi follows macOS's own Hindi terms (from the system's
`.loctable` files: सेटिंग, ऐक्सेसिबिलिटी, स्क्रीन रिकॉर्डिंग, कीचेन) so the names in
Foretype's text match what the user sees in System Settings.
**Cost.** Keys are English sentences: editing the English text means editing the key in
every language (`scripts/check-localization.py` lists what is missing). Text from the core
(error messages) stays English.

## D34. About You: deterministic fills, one identity, encrypted file (2026-10-22)

**Decision.** The user's own details (name, email, phone, company, job title, address,
website; one set per macOS account, the user's choice over several identities picked per
app) are filled in by rules in the core (`details.rs`), not by the model: a cue phrase on
the caret's line ("my email is", "Email:" at a line start, the line after "Regards,")
offers the exact value as a `details` suggestion, only when it matches what was typed.
The model sees them only through a `[Written by …]` header line (name, job title,
company), on by default with its own switch and never sent to an HTTP backend. The shell stores them in `about-you.bin`, sealed with
ChaCha20-Poly1305 under a Keychain key, and passes them through a new FFI call
(`ft_engine_set_details`) rather than the settings JSON.
**Why.** A value like an email address or phone number must be exact; a base model asked to
continue "My email is" invents a plausible address, and a writer line in the header only
makes that more likely to be the user's, never certain. Rules are exact, instant, work
with every backend (including Apple's model and servers) and are easy to test, including
the cases that must stay empty. They sit with the other typing aids, before the typo gate
(an address being typed is no typo) and are recomputed per keystroke, so they need no
cache or type-through. A cue list stays small and conservative because a wrong fill is
worse than none: "I'm", "it's", "Title:" and "Role:" are left out. A name goes word by word
(people often sign with the first name only); other details take one Tab. The writer line
was to stay off unless the corpus replay showed it doesn't hurt; it didn't (41.9% → 42.2%
with fills, 42.0% with fills alone, `docs/MEASUREMENTS.md`), and it never leaves the Mac,
so it is on. A separate FFI call keeps the details out of
`Settings` (serialized, cloned per keystroke, and the thing one would log), and lets the
shell send them only when they change. The file follows the writing history's pattern
(D14) instead of Keychain-only storage so the feature works the same way the user already
knows from personalization and keeps one small Keychain item; the Keychain is read at
launch only if the file exists.
**Cost.** English cue phrases only. A fill shows only at the end of a line. Phone numbers
must be typed the way they are stored ("+91 98765…" doesn't match "98765…"). Several
identities would need a picker and per-app mapping; the JSON shape leaves room for it.

## D35. Local builds sign with a self-signed "Foretype" identity (2026-10-22)

(Named "Foretype Local Dev" at first; renamed and shared with releases in D36.)

**Decision.** `scripts/make-signing-cert.sh` (run by the developer, once per Mac) puts a
self-signed code-signing certificate and key in the login keychain; `scripts/build-mac.sh`
signs with `FORETYPE_SIGN_IDENTITY` if set, else with that identity if present, else ad hoc.
Only an explicit identity (Developer ID) gets the hardened runtime and a secure timestamp.
**Why.** TCC stores the designated requirement of the app it granted. Ad hoc, that is the
build's cdhash, so every rebuild silently loses Accessibility and Screen Recording: the
toggle in System Settings looks on and tccd logs "Failed to match existing code
requirement". With a certificate the requirement is `identifier "dev.foretype.Foretype"
and certificate leaf = H"..."`, the same for every build (checked with `codesign -v -R`
across two builds). The certificate stays untrusted: codesign signs with it and the
requirement is a hash match, so no trust settings or admin password are needed. The
hardened runtime stays off because library validation needs a Team ID, which neither ad-hoc
nor self-signed signatures have; with it, Sparkle.framework fails to load. The script only
prints and asks: it changes the user's keychain, which tooling and agents must not do on
their own.
**Cost.** One more step for a new developer (optional; ad hoc still works), and one last
remove/re-add of the grants when switching from ad hoc. A bundle that keeps its grant is
live as soon as it opens, so UI-only tests launch it with `FORETYPE_ONLY_APPS` or build
with `FORETYPE_SIGN_IDENTITY=-`.

## D36. Public releases: self-signed, feed on GitHub Releases, silent install when idle (2026-10-22)

**Decision.** Releases are published on GitHub Releases of the public repository by
`.github/workflows/release.yml` when `scripts/release.sh` pushes a `v*` tag. The app is
signed with the self-signed "Foretype" identity (the same one local builds use, D35) and is
not notarized. Sparkle reads the feed from the latest release's own `appcast.xml` asset
(`.../releases/latest/download/appcast.xml`), checks daily, downloads by itself, and
`UpdateController` installs the download once the user has been idle for five minutes with
no suggestion on screen, then relaunches. `install.sh`, published with each release,
installs with one line of Terminal.
**Why.** The user chose not to pay for an Apple Developer ID for now. What a Developer ID
buys is a quarantine-free first launch. Everything else works without it: TCC grants keep
matching because the designated requirement is the certificate's hash, and Sparkle's
code-signature check passes between releases for the same reason. The EdDSA signature
remains the real proof that an update is ours. Browsers quarantine the DMG, and macOS 15+
then requires Open Anyway in System Settings (Control-click Open no longer bypasses it).
curl sets no quarantine attribute and neither do Sparkle's downloads, so the one-line
installer and every update skip Gatekeeper's prompt. One identity rather than separate
local and release certificates, because they share the bundle ID and so one TCC entry: two
certificates would keep invalidating each other on the developer's Mac. The feed as a
release asset needs no gh-pages branch and no manual appcast step: the
`releases/latest/download` URL always redirects to the newest non-prerelease. Install on
idle, because Sparkle's default (install on quit) almost never happens for a menu-bar app.
**Cost.** A browser download needs Open Anyway once. Two secrets must never be lost: the
certificate backup (losing it means one re-grant for everyone) and the EdDSA key (losing it
means installs stop updating). The feed holds one item: no delta updates and no history in
the feed. Moving to a Developer ID later means one re-grant for everyone. `curl | bash`
asks users to trust the script; it is published with each release, and it verifies the
DMG's checksum.

## D37. Pixel caret: one capture while typing where the estimate has no position (2026-10-22)

**Decision.** Once the pixel locator has learned an app's caret (colour and height, D31), a
field, line or wrapped line it has no position for is searched right away, 40 ms after the
snapshot, with one capture for every bar of that look; the row the caret moved to picks
the bar (`PixelCaret.choose`). Within about a word of the field's right edge the same
search runs on each change, since the host may wrap the word being typed. A suggestion
with no caret waits for such a search instead of showing the mirror card, and when no word
fits before the field's edge the first one runs past it. Empty fields are searched (blink)
on focus. The mirror card is left for when there is no estimate at all: the first field of
an app before its caret has blinked once.
**Why.** User report: in Electron chat composers the suggestion appeared in a card above or
below the line and moved next to the caret only after a pause. Typing keeps the caret
solid (toolkits restart the blink on input), so once its look is known a blink isn't
needed to see it; waiting for a pause cost the card on every new line and wrap, and the
first words of every new message. The report's card under the line had a second cause:
Chromium's ranges leave out the newline between paragraphs that its value counts, so the
last letter typed read as text after the caret (fixed in `FocusTracker`).
**Cost.** One capture of about 45 ms on a background queue per new field, line or wrap, and
a few per line end, while typing. Never per keystroke on a line whose position is known.
A `|` in the caret's colour and height alone on the next row could be taken for the caret
until the next pause's verify. Looks are kept in memory only (stored, they would list the
apps someone types in), so after a launch each app's first field still waits for a blink.

## D38. A default note for every app, measured; no per-app defaults (2026-10-22)

**Decision.** Custom instructions start as defaults from `core/data/default-instructions.json`
(`ft_default_instructions`): one note for every app, "Natural, clear writing that matches
the tone of the text so far, with correct spelling and grammar.", and no per-app notes. The
shell stores only what the user changes: an untouched note follows the installed version's
defaults, saving the default text again goes back to following them, an empty note the user
saves stays empty, and Restore Defaults in the editor brings them back.
**Why.** The note is part of the cached prompt header, so it costs nothing per keystroke, and
on the corpus it saved 0.7 points more typing with Gemma 4 E2B (42.8% → 43.5%) and raised the
Apple model's first-word accuracy from 17.0% to 19.8%. Per-app style notes ("Email: polite,
...") helped 3 of the 11 documents from a named app and hurt 5, so none ship; the format
keeps groups of apps for a measured per-app default later. The defaults live in the core so
every shell and `ft-replay --default-instructions` use the same text.
**Cost.** Measured on one model; the Qwen models (the default tier) weren't installed. Users
who saved an empty note before this version keep it empty (none expected: no one had saved
one through the editor on the developer's Mac).

## D39. Pause stops everything; power rules pause or save energy (2026-10-22)

**Decision.** "Suggestions On" is replaced by a pause: 15 minutes, 1 hour, until tomorrow
(6:00) or until resumed, kept in UserDefaults so it survives relaunches and updates (a saved
"off" becomes paused until resumed). Paused means no work at all, not a gate in the core:
the tracker's poll, AXObservers and activation observer are removed, both event taps are
off, pending screen and caret captures are dropped, the Chromium/Electron flags are put
back, and the core frees the model at once (`paused` in its settings, `status: paused`).
The same pause comes from power rules: on battery (save energy by default, or full speed,
or pause), Low Power Mode (pause by default, or save energy), battery below 10/20/30%
(off by default), thermal state serious (save energy) or critical (pause), and always
from sleep, a locked screen and display sleep. "Resume Anyway" sets the power reasons in
effect aside until they end or the Mac is plugged in. Saving energy is the old battery
behaviour (greedy, no prefetch, 80 ms mid-word debounce) plus no screen OCR and a 60 s
idle unload. Power and session changes arrive by notification; the 30 s poll is gone.
Option-click on the menu-bar icon and `foretype://pause|resume|toggle` pause from
anywhere; no global hotkey (user decision).
**Why.** The old switch only gated the core: the 0.5 s poll, the observers, the key taps
and Chrome's accessibility tree kept running, so "off" still cost wakeups and memory. Users
pause for a reason (a call, a battery, a game); the pause should end by itself where it can
and cost nothing while it lasts. Low Power Mode is the user saying energy matters more
than features, so it pauses by default (user decision); a battery threshold is opt-in
because the battery rule already saves energy.
**Cost.** Resuming re-primes Chromium and Electron apps, so their first suggestion takes the
2–3 s of D23 again, and the first suggestion after any pause waits for the model to load
(about 1 s). Pausing blocks the main thread up to 1 s while the flags are restored (also at
sleep). llama.cpp's Metal residency heartbeat (a 5 ms sleep loop for the life of the
process) can't be stopped by freeing the model and is most of what a paused Foretype still
costs; only `GGML_METAL_NO_RESIDENCY` at launch removes it, which needs its own latency
measurement (`docs/MEASUREMENTS.md`, *Pause and power*). The URL scheme lets any local app pause or resume Foretype (no more than a click on
the menu does). Defaults chosen with the user: Low Power Mode pauses, battery threshold
off, the Pause submenu replaces the switch.

## D40. A waiting update shows in the menu and Settings; scheduled checks never open a window (2026-10-22)

**Decision.** `UpdateController` tracks an update a check found that isn't installed yet
(`updater(_:didFindValidUpdate:)`), clears it when a check finds none
(`updaterDidNotFindUpdate(_:error:)`, which also covers a skipped version on scheduled
checks), when the user chooses Skip This Version (`userDidMake .skip`) and when the running
build is that version or newer, and keeps it across launches in the defaults
(`updateAvailableVersion`, `updateAvailableBuild`). While one is waiting, the menu-bar menu
shows "Update Available: X.Y.Z — Install…" under the status lines, and Settings ▸ General
shows "Version X.Y.Z is available" under the version with an Install… button. Both call
`checkForUpdates`, which brings Sparkle's own window (release notes, Install Update, Skip
This Version, Remind Me Later) to the front; Foretype doesn't install from the menu by
itself. For scheduled checks Foretype implements Sparkle's gentle reminders and always
handles the update itself (`standardUserDriverShouldHandleShowingScheduledUpdate` returns
false, also in "immediate focus" just after launch): no window, a dot on the menu-bar icon
until the user brings Sparkle's window up (`standardUserDriverDidReceiveUserAttention`) or
the session ends. Remind Me Later keeps the menu line; the dot comes back with the next
scheduled check. With automatic install on, the line shows between the check and the
idle-time install.
**Why.** With automatic install off, the only sign of an update was Sparkle's window from
the daily check, which for a menu-bar app opens behind other apps (or in front, just after
launch); after Remind Me Later or Skip nothing was left. Someone who turned automatic
install off wants to choose when, so the update should wait somewhere they look, not
interrupt typing. Sparkle 2 also logs a warning for background apps that check on a
schedule without gentle reminders. Skip hides the offer because the user said they don't
want that version; Sparkle won't offer it again on a schedule either, and Check for
Updates… still shows it. Install opens Sparkle's window rather than installing at once so
the user sees the release notes and so one code path (Sparkle's) installs.
**Cost.** A user who never opens the menu or Settings sees only a small dot in a template
glyph (no color). Critical updates get no special treatment. The offer kept in the defaults
can be up to a day stale if a release is pulled (the next check clears it). Verified with a
local feed by the app's own report of what its menu and Settings show
(`FORETYPE_UPDATE_REPORT`), not by clicking the real menu-bar item.

## D41. Romanized Hindi: a built-in word list overrides the spell checker (user decision, 2026-10-22)

**Decision.** The core carries about 470 common romanized Hindi words with their usual
spellings (`core/src/hinglish.rs`). A listed word is never autocorrected and a fragment
that starts one is never gated; when two of the last 40 words before the caret are listed,
the field counts as Hinglish and autocorrect and the typo gate stand down for every word.
A word typed earlier in the same field and kept also counts as known, in any language.
**Why.** The macOS spell checker knows no romanized Hindi: on en_IN it offered "hain" →
"hair", "mein" → "main", "tum" → "sum", and gated "jaldi", "matlab" and "kaam" mid-word:
on a 12-document Hinglish corpus, 172 false fixes and 188 false blocks, 4 and 4 with a list
written before seeing it, keystrokes saved 14.2% → 15.1%; the English corpus is unchanged
(`docs/MEASUREMENTS.md`). In Hinglish text the checker's verdict on the other words is
noise too, so the context rule turns it off rather than growing the list. The policy stays
in the core, needs no FFI change and works from a field's first word. Alternatives the user
weighed: only the field's own vocabulary (every Hinglish word still gets a wrong fix the
first time), the shell reporting how much of the recent text the checker flags
(language-agnostic, but an FFI change, more checker calls, and English full of names could
trip it), and a manual "I write Hinglish" setting.
**Cost.** English typos inside a Hinglish message are neither fixed nor gated. Words that
are also English (main, me, par, the, hum, sun, mat) are left off the list so that English
doesn't read as Hinglish; until a field has two listed words, unlisted spellings are still
judged by the checker. A typo the user kept once in a field isn't offered a fix again there.
The list is maintained by hand.

## D42. Context from other apps: opt-in, kept 10 minutes in memory, never for a server (user decisions, 2026-10-23)

**Decision.** Foretype will read text from apps other than the one being typed in (a
document, slides or a web page open beside the email being written) and from every
display, built in five phases (`docs/ROADMAP.md`, "Cross-app context"). The user decided:
- **Opt-in, with a setting of its own**, separate from Use Screen Context, which keeps
  reading only the focused window as today (D13).
- **Recently viewed windows are kept 10 minutes**, in memory only, and forgotten on pause,
  screen lock and sleep (the same events that pause Foretype, D39). Nothing is written to
  disk.
- **The default never-read list is password managers only.** Users can add any app; the
  existing per-app "suggestions off" and secure-input rules still apply on top.
- **Off entirely with a remote or bring-your-own server backend** (llama-server,
  OpenAI-compatible): text from other apps is only ever given to the on-device model.
- **8 GB Macs get it with a small budget** (decided after Phase A: "yes, allow 8 GB Macs
  with small budget"). On Macs under 12 GB of memory (the catalog's light tier,
  `models::recommended_tier`):
  - **Accessibility text only**: other apps' windows are never OCR'd there. The focused
    window's OCR (Use Screen Context) is unchanged.
  - **An other-app section of at most 512 tokens** (about 2,000 English characters),
    against a provisional 2,048 tokens on 16 GB and up.
  - **n_ctx stays 2048 with the f16 KV cache**, so no more KV memory than today.
  - Once Phase D brings the q8_0 KV cache, n_ctx 4096 costs the KV memory 2048 costs today
    (about 224 MB on Qwen3-0.6B and 1.7B); the section may then grow to 1,024 tokens if
    Phase C shows that more passages help.

**Why.** People write about what is on their other screen: figures from a spreadsheet,
dates from a slide, steps from a help page. The focused window's OCR (D13) can't see it.
Reading every app's text is more than people expect from an autocomplete, so it must be
asked for, separately from the focused-window feature they may already have on. Ten
minutes covers reading something and then switching to write about it, without building a
record of everything seen; memory-only and clearing on lock or sleep keep it from
outliving the session. Password managers show secrets by design, the one category that
never helps a suggestion; anything else sensitive (banking, health, chats) is the user's
call, and listing it by default would guess wrong for many people. Foretype's promise is
on-device: the focused window's text already reaches a server the user configured, but
other apps' text would send far more than the user is typing to anyone.
Phase A measured the gain on a corpus written to quote another app's window: +17 to +20
points of keystrokes saved on every model (Qwen3-1.7B 41.6% → 60.9%), a best case.
The 8 GB numbers come from Phase A (`docs/MEASUREMENTS.md`, "Cross-app context baseline").
The KV cache takes 112 KB per token on the two models an 8 GB Mac runs, so every 2,048
tokens of window cost 0.22 GB (f16) or 0.11 GB (q8_0); keeping n_ctx at 2048 makes the
feature free in KV memory. Today's prompt reaches about 1,100 tokens of English at most
(1,500 characters of screen text, a 1,600-character body, two 280-character examples, 400
characters of notes), so 512 more fit under the 1,984 the engine allows (n_ctx − 64) with
about 370 to spare. 512 tokens prefill in about 0.2 s on Qwen3-0.6B and 0.45 s on 1.7B
(2,840 and 1,190 tokens/s measured), short enough to finish in the background between
switching windows and typing, and a cache of about 1,600 tokens types no slower than Phase
A's full 2,048-token window (53 and 75 ms p50). The corpus's other-app texts are 111–286
tokens, so 512 holds one window whole or the best passages of two. Accessibility text needs
no Vision run per window (145–360 ms each, Phase 1+) and no Screen Recording for other
apps.
The 16 GB budget (n_ctx 4096, 2,048 tokens) is provisional for Phase C to tune: +0.22 GB
of KV on Qwen3-0.6B and 1.7B (f16), +0.29 GB on 4B, +0.05 GB on Gemma 4 E2B, and 0.7–4.5 s
of background prefill depending on the model. On every Mac the budget is counted in tokens,
not characters, and the other-app section is trimmed first when a prompt would overflow:
Devanagari costs Qwen3 about one token per character, so Hindi screen text alone can come
near the window.
**Cost.** A longer prompt header: every change to it costs a full prefill (D13; Phase A:
1.5 s for a full 2,048-token window on Qwen3-1.7B, 7.6 s for 8,192), and the bigger context
needs a bigger KV cache (+0.22 GB at 4,096 tokens, +0.67 GB at 8,192 for the models 8 GB
Macs use), so Phase D (background prefill, KV state cache, quantized KV,
flash attention, cheaper OCR) is part of the plan, not an extra. A document closed nine
minutes ago can still shape a suggestion. The password-manager list is kept by hand
(bundle IDs). People using a server backend don't get the feature. On 8 GB Macs, apps that
expose no text through Accessibility contribute nothing, and 512 tokens hold about a page.

## D43. Full-screen windows are captured through their display (2026-10-23)

**Decision.** `WindowCapture` (pixel caret and screen context) captures a window with
`SCContentFilter(desktopIndependentWindow:)` first. When that returns nothing it captures
the same rectangle with `SCContentFilter(display:including: [window])` on the display under
the rectangle's centre, and remembers the window so the failing attempt isn't repeated.
**Why.** In WhatsApp Web in the user's Chrome every caret capture failed, so suggestions
stayed in the card: the window was in native full screen, and for such a window the
desktop-independent filter fails with ScreenCaptureKit error -3811 ("Failed to start stream
due to audio/video capture failure") while the display filter limited to that window works
(`docs/MEASUREMENTS.md`). The display filter keeps what the locator relies on: only that
window's pixels, with no other window, Foretype's overlay or the pointer.
**Cost.** The display path sees only the part of the window on that display (a window
across two displays is clipped to the one under the field). A window that leaves full
screen keeps the display path until Foretype quits; it still works, as the display filter
captures windows that aren't full screen too. Measured only on macOS 27 with Chrome.

## D44. Other apps' text: what is read, and a sticky section at the head of the prompt (2026-10-23)

**Decision.** How Phases B and C carry out D42:
- **Reading.** Windows on screen on any display, visible when a quarter of them is not
  covered, plus the window focus just left (covered or not), read through Accessibility
  first; OCR (Vision `.fast`) only for windows that give under 200 characters, on 12 GB+
  Macs with Screen Recording, never while saving energy. At most 8 windows per refresh, 50
  ms per app, 6,000 characters per window, 12 windows in the pool. Refreshes on window or
  app switches and typing pauses (2 s, at most every 20 s), never per keystroke.
- **Gates.** Apps the user switched suggestions off in, or paused Foretype in, are not
  read; apps that are off only by default in the compatibility database (spreadsheets, code
  editors, terminals, remote desktops) are, and the password managers they include are on
  the never-read list. Windows that forbid capture and private browsing windows (by title:
  Incognito, InPrivate, Private Browsing, Private Window) are skipped; nothing is read while
  secure input is on.
- **Prompt.** The other-apps section is the prompt's first section, before the screen text.
  The core ranks ~300-character passages with BM25 against the committed text (its last 300
  characters doubled), the screen text and the title; windows on screen get a prior, so the
  window beside the field is offered before anything matches, and recently viewed windows
  need words in common. The selection is replaced only when another scores 25% plus one
  good term match higher, a passage left the pool or it no longer fits.
- **Budget.** Counted with a fitted estimate before the tokenizer is at hand (letters five
  to a token, digits, punctuation and non-ASCII characters one each), within
  `other_apps_tokens` and what `n_ctx` − 64 leaves after the rest of the header and a body
  reserve; a prompt that still overflows runs without the section. 512 tokens and n_ctx
  2048 under 16 GB (Macs of 12–15 GB too, where D42 gave no budget), 2,048 and n_ctx 4096
  from 16 GB, the larger context only while the setting is on (the built-in engine restarts
  when it is switched).
- `FORETYPE_OTHER_APPS=1|0` switches it for one process without touching the saved setting.

**Why.** A spreadsheet or a code editor is exactly what an email quotes ("contractors cost
$68,900"); turning suggestions off in an app says nothing about whether its windows may
inform suggestions elsewhere, but an app the user turned Foretype off in is one they want
left alone. The window just left is the one the user is about to quote, and is often
covered by the window they switched to. At the head of the prompt the section survives
moving between fields while the pool is the same, and the screen text that changes on every
field comes after it; it must then change rarely, since every change re-prefills the whole
prompt (Phase A: 1.5 s for a full 2,048-token window on Qwen3-1.7B), hence the sticky
selection and the warm-up as soon as the pool changes. On the multi-window corpus the real
section saves as much as Phase A's best case (`docs/MEASUREMENTS.md`, "Cross-app context: the
real section"); the Phase A stand-in, the other window pasted into the screen text, had no
budget, no ranking and no distractors. A character count would have let a sheet of figures
(Qwen3 spends a token per digit) run 56% over its budget; the fitted estimate is at most 5%
under the tokenizer on the corpus. Title keywords are the only sign of a private window
that browsers give other apps.
**Cost.** A private window whose title doesn't say so is read. A passage the user is
writing about but that shares no words with the text yet (a recently viewed window) waits
for the first matching words. On 16 GB Macs switching the setting reloads the model, and
the first suggestion after a pool change can wait for up to 2,048 more tokens of prefill
until Phase D moves it off the typing path. Accessibility text is what apps choose to
expose: Electron apps without their accessibility tree, canvas-drawn documents and Google
Docs without screen-reader support give nothing, and on 8 GB Macs there is no OCR to fall
back on.

## D45. A failed Keychain read never replaces a key (2026-10-23)

**Decision.** `Keychain.get` tells errSecItemNotFound apart from every other failure. The
writing history's key and the About You key are created only when the Keychain has no item
*and* there is no file (or an empty one) the key could have opened. Any other result (the
user denied or cancelled a prompt, the keychain is locked, interaction isn't allowed, the
app's signature changed, a malformed item, or a file without its key) locks that store for
the run: nothing is recorded, opened, saved or deleted, and the user gets a non-blocking
note with Try Again (the Personalization menu and pane, the About You pane). `Keychain.set`
updates the item in place and adds one only when there is none.
**Why.** Before, any failed read counted as "no key yet": a new key was made and written
with delete-then-add, so one click on Deny (or a rebuild that changed the dev build's
signature) made the existing history and details unreadable for good. The file is the
user's data; the key is the only way to read it. Not being able to learn for a while is
cheap, losing months of writing is not. Delete-then-add also left no key at all whenever
the add failed. A locked store doesn't ask the Keychain again on every engine restart:
one prompt per run, then only when the user asks.
**Cost.** A history file whose key really is gone (deleted by hand in Keychain Access, a new
Mac without the item) stays locked until the user deletes the history; the note says so.
A details file that decrypts to nothing with a readable key is still treated as empty and
overwritten on the next save (the key wasn't the problem there).
**Server API key.** The same rule holds for the server backend's API key, which has no
file to protect but is the user's secret: a failed read gives the engine no key for that
run and the server fields say the saved key can't be read; the fields are never pre-filled
and only a key the user types is written (in place), so neither a failed read nor an empty
field can blank or delete it. The fields remember the read for the run, so a denied prompt
doesn't come back on every refresh of the Settings window.

## D46. The core never writes to a history its key can't open (2026-10-23)

**Decision.** `History::open` counts the whole frames in the file and the ones that decrypt.
Frames but none that open, or a file that exists but can't be read, make the history
**locked**: no records, and `append` and compaction fail without touching the file. The
state is reported as `"locked"` in `ft_engine_history_stats`; the Mac shell shows it as a
locked history with its own note ("the key in your Keychain doesn't open your writing
history"). Only clearing the history (the user's Delete) removes the file and unlocks it
under the same key. One undecryptable frame among good ones is still damage: skipped, and
dropped at the next compaction.
**Why.** Before, a wrong key read 0 records but kept appending frames sealed under itself to
the same file, and the first compaction rewrote the file from those alone, destroying every
frame the right key could have opened. D45 stops the shell from making a wrong key after a
failed Keychain read, but a key can still be wrong (a Keychain item restored from elsewhere,
a history file copied from another Mac, a future bug), and the core is the last place that
can refuse. A history that can't learn for a while is cheap; one rewritten without its old
frames can't be recovered.
**Cost.** A history whose key is truly gone stays locked until the user deletes it. A file
that was written under two keys (by builds before this fix) opens with either one, and the
next compaction under that key still drops the other key's frames.

## D47. Other apps' text off the typing path: two prompts in the KV cache, the old header while the new one prefills, saved contexts, q8_0 (2026-10-23)

**Decision.** Phase D of the cross-app context plan (D42):
- **Two slots.** The built-in engine keeps two prompts in one unified KV cache, each a
  llama.cpp sequence. When a request's prompt costs more than 48 tokens of prefill and
  differs from what the serving slot holds only in text read from screens, it is served
  with the serving slot's header (in the same field: its whole header, other-apps section
  and screen text; in another field: only its other-apps section), and its own prompt is
  prefilled into the other slot between keystrokes, about 40 ms at a time. The next request
  whose prompt is in that slot is served from it. Prompts that share the other-apps section
  share its cells. Warm-ups (focus changes, new screen text, a new pool) go the same way.
  Recurrent models keep one slot and prefill as before.
- **Never stale text that was taken away.** The old header is used only while every
  passage of its other-apps section is still in the pool; a pool emptied after holding text
  (pause, lock, sleep, the setting switched off) clears the KV cache and every saved
  context before the next request.
- **Saved contexts.** A slot about to be reused for another prompt of 256 tokens or more is
  copied out of the KV cache (`llama_state_seq_get_data`) into an LRU in memory and
  restored when a request shares a longer prefix with it than with any slot: 384 MB from
  16 GB, 128 MB from 12 GB, none under 12 GB; each is dropped 10 minutes after it was
  saved.
- **q8_0 KV cache while other apps' text is on**, f16 otherwise (flash attention, which
  q8_0 needs, was already on: llama.cpp turns it on by itself with Metal). With the setting
  on the context is 4,096 tokens, otherwise 2,048. Under 16 GB both slots share one
  context's cells (4,096 q8_0 or 2,048 f16: the KV memory 2,048 f16 cells took before);
  from 16 GB each slot gets its own. Switching the setting restarts the built-in engine on
  every Mac.
- **Cheaper OCR of other windows**: at most 400 ms of OCR per refresh, and a refresh after a
  typing pause doesn't capture a window it OCR'd less than a minute ago. Pictures are not
  downscaled.

**Why.** Every change to the header used to cost the next keystroke a full prefill: on
Qwen3-1.7B with a full 2,048-token section the first suggestion after a change took 1,055
ms at p50 and 1,624 at p90 (`docs/MEASUREMENTS.md`, "Cross-app context: performance").
Served with the old header it takes 108 / 179 ms; the old header is what the user had a
second ago, so a few keystrokes of slightly stale context cost little. Prompts that differ
only after the section share its cells, so a new screen text costs only its own tokens,
and a second sequence in the same context is cheaper than a second context (no second
compute buffer, shared prefixes). A field the user returns to after the two slots moved on
would otherwise be prefilled again; a copy in memory restores in milliseconds, and ten
minutes and the pool's own clearing keep it from outliving the text it holds. q8_0 saves
the same keystrokes on both corpora and halves KV memory (n_ctx 4096 in q8_0: 399 MB on
Qwen3-1.7B against 385 MB for 2048 in f16), which pays for the second slot and the larger
context; it is no slower against long prompts (82 vs 89 ms at 4,096 tokens) but 6–10 ms
slower at p50 on short ones, so people who don't use other apps' text keep f16. A smaller
OCR picture took Vision as long and read fewer words (87% of 13 pt words at one pixel per
point), so the OCR saving comes from doing less of it.

**Cost.** With a full 2,048-token section the new header is ready only 3.1 s (p50) after a
change if the user types without stopping, and keystrokes meanwhile take 122 / 220 ms
(p50 / p90) instead of about 80 / 114, as one can wait for a 40 ms background step; the 2 s
aimed for holds for sections the size the corpus has (under 0.3 s) or after a pause (2.1–2.4
s). A few suggestions after a change still use the old text. Memory from 16 GB: two q8_0
slots at 4,096 tokens take 26 MB more than one f16 slot did (639 vs 613 MB), plus up to 384
MB of saved contexts; without other apps' text the second f16 slot adds 224 MB. Saved
contexts duplicate the other-apps section they share (llama.cpp saves whole sequences).
Recurrent and hybrid models (none in the catalog) keep one slot and still make the next
keystroke wait. Switching the setting now reloads the model on Macs under 16 GB too.
