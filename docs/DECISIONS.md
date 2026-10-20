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
geometry (mirror card for now; a pixel locator is on the roadmap).

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
`workflow_dispatch` only. Restore push triggers only when the user asks.

## D19. Development safety on a shared Mac

After an unrestricted dev run briefly suggested in the user's Teams: all dev and test runs
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
