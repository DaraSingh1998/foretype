# Plumbing, Not Models, Powers Cotypist's Autocomplete

Cotypist is a closed-source menu-bar app for Apple Silicon Macs. It reads the text field you are typing in through the macOS Accessibility API, runs a small open-weight model locally through **llama.cpp** (Google's **Gemma 4 E2B** by default), and draws a few words of gray "ghost text" at the caret. Press **Tab** and it types the next word into the host app; press the key above Tab and it types the whole suggestion. It is free for **100 accepted words a day**, then costs **$72 a year (Plus) or $108 a year (Pro)**. Its privacy story is strong on inference, since nothing you type leaves the Mac, but weaker on defaults, since anonymous analytics and crash reports stay on until you opt out. The developer has confirmed the runtime, the default model, the permission model, clipboard-based insertion of long completions, and an encrypted, opt-in personalization store. The overlay window, the key-interception design, KV-cache reuse and the personalization algorithm are inferences. They rest on code in roughly twenty open-source clones that rebuilt the same pipeline during 2026. The most important finding is that the model is not the moat. One open-source author ran Cotypist's own model file in his pipeline and found it saved about **20% fewer characters** than an off-the-shelf Qwen3-4B base model. That leaves per-app compatibility heuristics as Cotypist's real asset. The macOS clone space is already crowded and converging, so a new free equivalent should compete on portability and licensing. The recommended design is an **Apache-2.0 Rust core** (context builder, llama.cpp engine with prefix-cache rollback and token healing, suggestion cache, per-app policy, personalization) behind thin native shells. It starts with a Swift macOS shell seeded from MIT-licensed Tabber and KeyType code, defaults to Apache-2.0 **Qwen3 base** models, and ships as a notarized, unsandboxed DMG with Sparkle updates. Windows and Linux shells follow, built on UI Automation (later TSF) and Fcitx5/IBus.

## Cotypist sells inline next-word prediction for up to $108 a year

### Tab takes one word, the key above Tab takes the rest

Cotypist "predicts your next words in every Mac app" and runs "on your Mac, not in the cloud" ([Cotypist](https://cotypist.app)). It is made by **Daniel Gräfe**, the solo, non-venture-funded maker of the time tracker Timing, through **Accelerated Thought GmbH** in Munich ([Press kit](https://cotypist.app/press)). The company was founded on March 28, 2025 ([Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)). Older sources credit Timing to a Munich developer named Daniel Alm ([IndieHackers](https://www.indiehackers.com/interview/the-distribution-channels-i-targeted-to-generate-2-000-mo-150a65a05b)), so these are probably one person after a name change, though no source confirms it. The app spent more than a year in free beta: it was at v0.7.2 by March 2025 ([MacSparky](https://www.macsparky.com/blog/2025/03/cotypist-ai-autocompletion-everywhere-on-your-mac/)) and v0.17.1 by December 2025 ([MacUpdater](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html)). It launched commercially on **May 27, 2026** and has since moved to calendar-style versions such as 2026.4 ([MacSparky, Oct 2026](https://www.macsparky.com/blog/2026/10/cotypist-2026-4-syncs-your-writing-between-macs/)).

The visible behavior is simple. Gray ghost text appears inline at the caret in the host field's font. It regenerates after every keystroke, and if you type through a near-miss it realigns "within a letter or two" ([Cotypist](https://cotypist.app); [Daring Fireball](https://daringfireball.net/linked/2026/06/18/cotypist)). The developer says "the first word or two of a suggestion tend to be most reliable" ([Tips](https://cotypist.app/help/tips)), and the keymap follows from that. **Tab inserts the next word** and steps through the suggestion on repeated presses. The physical key above Tab (` / § / ^ depending on layout) accepts everything. **Esc dismisses the suggestion and briefly pauses** suggestions in that field; it can instead be set to switch the app off until you change apps, or to leave Esc alone. Once no suggestion is showing, Esc passes through ([Shortcuts](https://cotypist.app/help/shortcuts)). Option+Tab sends a literal Tab. Ctrl+` force-activates completion in fields where Cotypist deliberately stays quiet, and Ctrl+Option+Cmd+` snoozes the current app for a few minutes. The official pages disagree on one detail: the Tips page calls the accept-all key "unassigned by default," while the Shortcuts page lists it as a default ([Tips](https://cotypist.app/help/tips)).

Much of the product's polish is in knowing when *not* to suggest. Cotypist "intentionally stays idle in small text fields" and in Google Sheets cells, so Tab still moves between fields ([Troubleshooting](https://cotypist.app/help/troubleshooting); [Compatibility](https://cotypist.app/compatibility)). It leaves code editors' main buffers alone by default and works only in VS Code, Cursor and Windsurf sidebar chats. In Terminal and iTerm it activates only when it detects an AI-agent prompt from Claude Code, Codex, OpenCode, pi or Kilo CLI, including inside tmux and zellij ([Compatibility](https://cotypist.app/compatibility)).

Several features sit on top of this core loop:

- **Completion length**, from 1–2 words up to "Very Long" (10–15 words). One reviewer measured about 2 seconds for "Very Long" on an M1 Max ([Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)).
- **Custom instructions**: a global note pre-filled from the Mac's language and region, with per-app and per-domain instructions appended after it ([Personalization](https://cotypist.app/help/personalization)).
- **Emoji** via colon shortcodes.
- **Inline autocorrect**, added in v0.22.
- **Labs**: word alternatives, synonyms for a selection, mid-line completion and right-to-left support ([MacSparky, May 2026](https://www.macsparky.com/blog/2026/05/cotypist-brings-smart-autocomplete-to-every-mac-app/); [Tips](https://cotypist.app/help/tips)).

### A 100-word free tier funds one developer's compatibility grind

| Tier | Price (USD) | What you get |
|---|---|---|
| Free | $0 | 100 Tab-accepted words/day on 1 Mac. Default short length only, typo indicator instead of autocorrect, personalization capped at "gentle" |
| Plus | $72/yr ($6/mo billed annually), or $8 month-to-month | Unlimited on 1 Mac. Full autocorrect, configurable length, global instructions, "balanced" personalization |
| Pro | $108/yr ($9/mo billed annually), or $12 month-to-month | Up to 3 Macs. Full model catalog (incl. Gemma 4 26B A4B, Qwen 3 30B-A3B), per-app instructions, clipboard awareness, mid-line completion, Labs |

The prices above come from the official pricing page and press kit ([Pricing](https://cotypist.app/pricing); [Press kit](https://cotypist.app/press)). Every install starts with a **30-day Pro trial that needs no card**. Only words accepted with Tab count against the free limit, and checkout runs through Paddle. Nothing indicates a lifetime license. The app was free throughout the beta. In January 2026 the planned post-trial tier was 50 words a day under the name "Casual" ([Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)). The developer justifies the subscription by the ongoing cost of supporting many apps ([Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)).

That cap is the most frequently cited motive for open-source clones. Typist's author writes that Cotypist "used to be free; then it started capping how many words you could complete per day unless you paid" ([Typist README](https://github.com/BrodySalvucci/Typist)). Paid rivals mostly compete on lifetime pricing rather than platforms: Typeahead charges $96/yr or $149 lifetime ([Typeahead](https://www.typeahead.ai/)), and MacAutocomplete charges $125 lifetime ([MacAutocomplete](https://macautocomplete.com/)). Typilot claims local ghost text on macOS, Windows and Linux for $199 lifetime, but that claim comes only from its own marketing ([Typilot](https://typilot.com/alternatives/cotypist)).

### Inference stays local, but analytics ship switched on

Cotypist's privacy page says the model "runs locally on your device." It says typed text is never sent because "we have nothing to send even if we wanted to" ([Privacy overview](https://cotypist.app/help/privacy)). Each data source has its own rules:

- **Focused field.** Accessibility reads only the field you are typing in. macOS blocks password fields unless a site's "reveal password" is clicked ([Privacy policy](https://cotypist.app/privacy)).
- **Screen context.** Optional Screen Recording adds nearby on-screen text through "on-device text recognition." It is enabled by default once the permission is granted, and screenshots are "never stored or transmitted" ([Privacy policy](https://cotypist.app/privacy)).
- **Clipboard.** Clipboard awareness is a Pro feature, off by default, and works "in memory only."
- **Personalization history.** Recording your writing is off by default. When enabled, it lives in an encrypted local database whose key is in the Keychain, and the derived profile is "never synced."
- **Sync.** Optional iCloud sync of writing history is end-to-end encrypted ([Personalization](https://cotypist.app/help/personalization); [Privacy overview](https://cotypist.app/help/privacy)).

The weak point is defaults. **Anonymous usage statistics and crash reports are on by default.** Crash reports go to Sentry and usage counts to Google BigQuery, both in Frankfurt, and the privacy policy also lists Fathom analytics. License validation and update checks send the license key, email, computer name and an anonymous Mac identifier ([Privacy overview](https://cotypist.app/help/privacy); [Privacy policy](https://cotypist.app/privacy)). Hardware requirements are Apple Silicon and macOS 14 or later, with an M1 Pro or M2 and 16 GB recommended, and the app uses 1–2.5 GB of memory while active ([Cotypist](https://cotypist.app)). Reviewers report a noticeable battery cost on laptops ([Nic's notes](https://notes.nicolasdeville.com/apps/cotypist/)).

### Apps that draw their own text defeat it

Cotypist works wherever an app exposes text and character geometry to Accessibility. That covers native Cocoa apps, Safari, Chrome, Brave and Edge, Word, Apple Mail, Notion, Obsidian, Teams and WhatsApp; Slack is listed as "partial" ([Compatibility](https://cotypist.app/compatibility)). Apps that render text themselves fail: Google Slides, Zed, Sublime Text, OneNote, Anki, Thunderbird, Ghostty, Warp, Kitty, and virtual machines or remote desktops. Google Docs works only after you enable Docs' own screen-reader and braille support. Arc and Dia show suggestions in a floating "mirror" window above the field unless you enable "Text Metrics" at `chrome://accessibility` or launch with `--force-renderer-accessibility=complete`. Firefox and Zen are mirror-only ([Compatibility](https://cotypist.app/compatibility); [Troubleshooting](https://cotypist.app/help/troubleshooting)).

Reception is warm but split. John Gruber calls the suggestions "eerily good" yet says he "can't stand using it" because good suggestions distract him ([Daring Fireball](https://daringfireball.net/linked/2026/06/18/cotypist)). Recurring complaints are distraction, RAM and battery use, weaker non-English output, and the tight free tier ([Nic's notes](https://notes.nicolasdeville.com/apps/cotypist/); [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)). The developer reports users with ALS, including two who type through Neuralink implants ([Product Hunt](https://www.producthunt.com/products/cotypist)). For those users, autocomplete is an accessibility tool, not a convenience.

## Cotypist confirms what it does but rarely how

Cotypist publishes no changelog, acknowledgements page, engineering blog or technical talk. Its prompt template reportedly ships with encrypted delimiters ([TabType COMPARISON.md](https://raw.githubusercontent.com/nilava/TabType/main/docs/COMPARISON.md)). The technical evidence therefore falls into three tiers:

1. **Confirmed by the maker**: the help, privacy and press pages, plus the developer's Product Hunt replies.
2. **Observed by third parties**: mainly the MIT-licensed clone TabType. Its author says he "studied Cotypist's observable behaviour and the structure of its app" and ran Cotypist's model file in his own pipeline ([TabType README](https://github.com/nilava/TabType)). TabType is one interested source, and it does not say claim by claim whether each finding came from behavior or from inspecting the app bundle.
3. **Inferred**: reasoning from platform constraints and from open-source code that solves the same problems.

| Layer | Confirmed by Cotypist | Reported by third parties | Inferred mechanism |
|---|---|---|---|
| Capture | Accessibility reads the field and inserts completions; it is the only required permission ([Troubleshooting](https://cotypist.app/help/troubleshooting)). Optional on-device OCR adds screen context. Context includes app, window title, URL and surrounding text ([Privacy overview](https://cotypist.app/help/privacy)) | Chat context comes "from the screen only"; small fields are skipped ("size gate") ([TabType COMPARISON.md](https://raw.githubusercontent.com/nilava/TabType/main/docs/COMPARISON.md)) | `AXFocusedUIElement` → `AXValue` / `AXSelectedTextRange` / `AXBoundsForRange` with `AXObserver`. Vision OCR on ScreenCaptureKit captures. "Improve Compatibility" probably toggles Chromium/Electron AX flags |
| Overlay | Inline ghost text, mirror-window fallback, an icon beside fields, numbered pickers for alternatives ([Compatibility](https://cotypist.app/compatibility); [Tips](https://cotypist.app/help/tips)) | Caret sanity checks, snap to line, retries at 40/80/160 ms, per-field line-height cache ([TabType README](https://github.com/nilava/TabType)) | Borderless, non-activating, click-through `NSPanel` at the AX caret rect. Font approximated from line height |
| Keys | Tab, key above Tab, Esc, Option+Tab, Ctrl+`. Secure Input "can block single-key shortcuts system-wide" ([Troubleshooting](https://cotypist.app/help/troubleshooting)) | "Listen-only key tap" ([TabType COMPARISON.md](https://raw.githubusercontent.com/nilava/TabType/main/docs/COMPARISON.md)) | Keys consumed only while a suggestion is visible, through a tap created under the Accessibility grant (no Input Monitoring) |
| Insertion | Uses the clipboard briefly for longer completions, restores it, and marks the temporary content for clipboard-history tools ([Privacy policy](https://cotypist.app/privacy)) | Per-app strategies: "typing / per character / chunks / paste / first word typed" ([TabType COMPARISON.md](https://raw.githubusercontent.com/nilava/TabType/main/docs/COMPARISON.md)) | `CGEventKeyboardSetUnicodeString` for short text. Cmd-V with a transient pasteboard type for long text |
| Inference | llama.cpp with Gemma 4 E2B default. About 1 GB active memory "because weights are streamed from disk." Unloads when you stop typing ([Product Hunt](https://www.producthunt.com/products/cotypist); [Press kit](https://cotypist.app/press)) | Its own 3.4 GB quantization. Sectioned, token-budgeted prompt. 9-wide phrase beam. 2/4/7/10-word targets. No fixed debounce ([TabType README](https://github.com/nilava/TabType)) | mmap plus Gemma's per-layer embeddings explain the low resident memory. Used as a raw continuer. KV prefix reuse with cancel-and-restart on each keystroke |
| Personalization | Opt-in encrypted history (key in Keychain). A "derived personalization profile" nudges word choice, set by a strength slider ([Personalization](https://cotypist.app/help/personalization)) | — | Decode-time logit bias or beam re-ranking from word/phrase frequencies. No fine-tuning |
| Stack | Notarized direct DMG with auto-updates. Sentry, BigQuery, Fathom, Paddle, Cloudflare, Hetzner ([Press kit](https://cotypist.app/press); [Privacy policy](https://cotypist.app/privacy)) | Uses Sparkle ([TabType COMPARISON.md](https://raw.githubusercontent.com/nilava/TabType/main/docs/COMPARISON.md)) | Native Swift/AppKit, linking llama.cpp with the Metal backend |

**Capture is confirmed at the level of APIs, not attributes.** The troubleshooting page says Cotypist "relies on the macOS Accessibility API to read the text field you're typing in and insert completions." On macOS 27 that permission is now called "Device Control and Data Access," and Cotypist "can't work without it" ([Troubleshooting](https://cotypist.app/help/troubleshooting)). Screen context is genuinely useful: one reviewer found suggestions noticeably worse without Screen Recording ([Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)). Cotypist never names the AX attributes it reads, but its own workaround for Arc and Dia is revealing. Turning on Chromium's "Text Metrics" mode makes the browser compute per-character bounds. That implies inline placement depends on `AXBoundsForRange`-style geometry and that the mirror window is the fallback when geometry is missing (inferred).

**The overlay and key handling are inferred from what macOS allows.** No third-party app can draw inside another app's text view. The ghost text must therefore be a separate transparent window positioned over the caret, and the mirror fallback fits a window that lacks a caret rectangle (inferred). TabType reports that its first version "felt worse" than Cotypist because "the ghost sat in the wrong place, appeared late," which is why it copied Cotypist-style caret checks and retries ([TabType README](https://github.com/nilava/TabType)). A reviewer describes both Cotypist and the clone Cotabby as "a bit hacky" in how they find the cursor ([Ole Reissmann](https://olereissmann.com/cotypist-and-cotabby-local-ai-autocomplete-for-writers/)).

Cotypist's docs list Accessibility as the only required permission and never mention Input Monitoring ([Troubleshooting](https://cotypist.app/help/troubleshooting)). Apple's developer support says plain event taps use separate listen/post services, and that the Accessibility privilege is needed only "if you're doing other stuff with Accessibility APIs" ([Apple Forums 744440](https://developer.apple.com/forums/thread/744440)). Developers also report that an app holding Accessibility gets no Input Monitoring prompt ([Apple Forums 122492](https://developer.apple.com/forums/thread/122492)). Together these fit an active keyboard tap running under the Accessibility grant (inferred).

**The inference stack is the best-documented layer.** The developer confirms Gemma 4 E2B, "a few GB on disk" but about 1 GB of active memory. On Max and Ultra Macs the larger E4B uses about 2.5 GB, and the model "winds down and frees that memory when you're not actively typing" ([Product Hunt](https://www.producthunt.com/products/cotypist)). Models download after install rather than shipping in the DMG ([Troubleshooting](https://cotypist.app/help/troubleshooting)). The catalog has churned: Gemma 3 was the default in December 2025, and Ministral 3B arrived in v0.17.1 ([Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/); [MacUpdater](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html)). An earlier report named Qwen 2.5 1.5B with a 100–200 ms cycle, but it probably describes a pre-launch build ([Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)).

TabType adds the most useful detail. Cotypist ships its own 3.4 GB Gemma 4 E2B quantization. It wraps prompt parts in "delimited, token-budgeted sections." It runs a "9-wide beam search over whole phrases" that may replace the first word, and it offers no suggestion while a partly typed word "can't become a real word." Length presets are 2, 4, 7 and 10 words, with no fixed waits. Most tellingly, TabType ran Cotypist's model file in its own pipeline: it was **about 50 ms faster but saved 20% fewer characters** than TabType's Qwen3-4B base (1.17 vs 1.46 characters per accept on the author's writing). TabType's conclusion: "The model isn't Cotypist's edge" ([TabType README](https://github.com/nilava/TabType); [TabType COMPARISON.md](https://raw.githubusercontent.com/nilava/TabType/main/docs/COMPARISON.md)).

**Personalization is confirmed as a data store, not as an algorithm.** By default, recording captures only fields where you accepted a completion, and it skips short texts and password fields. A "derived personalization profile nudges the AI toward words and phrases you actually use." At the strongest setting it "can override a better-fitting word in favor of a frequently used one" ([Personalization](https://cotypist.app/help/personalization)). The developer calls the adaptation "a mix of both 'global' and context-specific" ([Product Hunt](https://www.producthunt.com/products/cotypist)). Overriding a better word with a frequent one is what a decode-time frequency bias does, not what fine-tuning does. Deleting the data restores "unmodified model behavior" immediately, which also argues against weight updates (inferred).

## Open-source clones show how each layer actually works

Where Cotypist is silent, four MIT-licensed Swift clones (Tabber, KeyType, Typist and TabType) and the AGPL-licensed Cotabby document the same problems in code and comments. One research pass described Cotabby as MIT. The GitHub API reports **AGPL-3.0**, and this report treats it that way ([Cotabby](https://github.com/FuJacob/cotabby)).

### Accessibility is eventually consistent, so readers poll, retry and time out

Every working clone reads the same way. It gets `AXUIElementCreateSystemWide()`, reads `AXFocusedUIElement`, and fetches `AXValue`, `AXSelectedTextRange`, `AXNumberOfCharacters` and the marked-text range. It then calls parameterized `AXStringForRange`, `AXBoundsForRange` and `AXAttributedStringForRange` for windowed text, geometry and font. In web content it uses the WebKit/Chromium text-marker family instead ([Tabber AXClient.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/AXClient.swift)). Tabber batches reads with `AXUIElementCopyMultipleAttributeValues` and falls back to per-attribute calls. In that fallback it stops at the first failure, because "a dead or hung app fails every attribute the same way."

No change signal is reliable on its own. Tabber therefore combines three: AXObserver notifications, a burst of re-reads after each keystroke, and a 0.5-second idle poll that backs off. It reads a window of 4,000 UTF-16 units before the caret and 1,000 after ([Tabber FocusTracker.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/FocusTracker.swift)). All AX traffic runs on a dedicated run-loop thread "so a slow app can never stall the main thread" ([Tabber AXThread.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/AXThread.swift)). The global messaging timeout is clamped to **80 ms**; Cotabby uses 50 ms and Typist 250 ms ([Typist AccessibilityReader.swift](https://github.com/BrodySalvucci/Typist/blob/HEAD/Sources/Typist/AccessibilityReader.swift)).

One trap catches naive readers. IME compositions and macOS's own inline predictive text, which is on by default in every `NSTextView`, appear in `AXValue` as if the user had committed them. A naive reader then paints a second completion over the system's. Cotabby therefore suppresses its ghost text whenever a marked range is present ([Cotabby HostMarkedTextPolicy.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Support/Input/HostMarkedTextPolicy.swift)).

### Chromium hides caret geometry until coaxed

Chromium and Electron build their accessibility trees lazily. Electron documents that assistive tools can set `AXManualAccessibility` on the app element ([Electron docs](https://www.electronjs.org/docs/latest/tutorial/accessibility)). Chrome itself needs the VoiceOver signal `AXEnhancedUserInterface`. Cotabby measured in September 2026 that "all four test fields returned empty bounds and an empty font dictionary until this flag was set." It also found that VS Code must be re-primed on every activation, because the tree "stays dormant for minutes" otherwise ([Cotabby ChromiumAccessibilityEnabler.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Focus/Chromium/ChromiumAccessibilityEnabler.swift)).

The flag has costs. It disturbs window managers ([Apple Forums 659755](https://developer.apple.com/forums/thread/659755)), and Rectangle switches it off around every resize ([Rectangle AccessibilityElement.swift](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift)). Tabber observed Chrome clearing it "within 50 ms" of each activation, so it reads the value back and re-asserts it ([Tabber WebAccessibility.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/WebAccessibility.swift)). Gmail compose lives in an out-of-process iframe that only `AXUIElementCopyElementAtPosition` can reach ([Cotabby AXHelper.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Support/Accessibility/AXHelper.swift)). Together these explain Cotypist's "Improve Compatibility With This App" button and its Arc/Dia instructions.

### Caret rectangles fail in seven documented ways

`AXBoundsForRange` with a zero-length range works in TextKit apps and misleads almost everywhere else. Tabber's validation code lists the failures ([Tabber CaretMath.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberAX/CaretMath.swift)):

1. A rect at the screen origin, meaning "don't know" ("real text can't be there: the menu bar is").
2. The element's whole frame instead of a caret.
3. A bottom-left origin.
4. Backing-pixel coordinates instead of points.
5. A single "character" rect that spans a whole line.
6. A zero-length rect "one line too high in TextKit" after a newline.
7. Empty rects everywhere, as in Microsoft Teams.

Robust code rejects implausible candidates. It tries the previous character's trailing edge, repairs flipped or pixel-scaled rects, and falls back to the frame of the last text run, an estimate from the field frame, or a mirror card ([Tabber compatibility.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/compatibility.md)). Cotabby goes further for hosts that expose nothing, such as Obsidian's CodeMirror and Chrome's address bar. It captures the host's pixels with ScreenCaptureKit and takes the right edge of the last inked line ([Cotabby PixelCaretLocator.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Presentation/PixelCaretLocator.swift)).

Font matching follows a similar ladder. The `AXFont` attribute carries name, family and size. When name and family disagree, as with Word's fake "Helvetica," the family wins. When an app reports only a size, as Chrome does, Tabber matches the rendered width of a sample against candidate families, then draws the ghost in the host text color at about half opacity ([Tabber FontResolver.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberOverlay/FontResolver.swift)).

### A narrow key tap and synthetic Unicode keystrokes beat the clipboard

The overlay itself is settled practice. It is a borderless, transparent, click-through `NSPanel` with `.nonactivatingPanel`, `canBecomeKey` set to false, `setAccessibilityElement(false)`, and collection behavior that joins all Spaces and full-screen apps ([Tabber GhostPanel.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberOverlay/GhostPanel.swift)).

Key interception is subtler. Tabber's session tap callback "never blocks, never calls Accessibility, and never waits on the main thread." It returns nil to swallow a key, swallows the matching keyUp too, re-enables itself after a timeout, and ignores its own synthetic events by checking a marker in `eventSourceUserData` ([Tabber KeyboardMonitor.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/KeyboardMonitor.swift)). Cotabby refined this into two taps. A permanent listen-only tap observes typing and cannot stall input. A consuming tap is installed only while a suggestion is visible, a design adopted after an always-active tap broke spacebar play/pause in DaVinci Resolve. Cotabby also delays tearing down that tap by 50 ms so the last synthetic keystroke drains through it ([Cotabby InputMonitor.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Services/Input/InputMonitor.swift)).

Two hazards shape the design. While Secure Event Input is on, the tap "receives no key events at all" ([Tabber KeyboardMonitor.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/KeyboardMonitor.swift); [Apple TN2150](https://developer.apple.com/library/mac/technotes/tn2150/_index.html)). Some apps leak secure input until they quit: one Cursor forum thread reports it breaking all system-wide taps ([Cursor forum](https://forum.cursor.com/t/cursor-leaks-secure-event-input-breaks-all-system-wide-input-taps-until-quit-or-screen-lock/167585)). And revoking Accessibility while an active tap runs can freeze input ([Apple Forums 844416](https://developer.apple.com/forums/thread/844416)).

For insertion, clones default to keyboard events carrying Unicode strings. The host sees typing, so undo, styling and web input events behave naturally. Several implementation details matter:

- **Chunk size.** Each event carries at most 20 UTF-16 units, a limit espanso also hit ([espanso native.mm](https://github.com/espanso/espanso/blob/dev/espanso-inject/src/mac/native.mm)).
- **Virtual key code.** Tabber uses key code 0 ("A"). It avoids codes that web pages see as Space or Enter, and unassigned codes that Chrome drops.
- **Newlines.** These are sent as real Return presses.
- **Posting point.** Events go to `.cgAnnotatedSessionEventTap`, which skips every session tap, including the app's own ([Tabber TextInserter.swift](https://github.com/chriscorbell/tabber/blob/HEAD/Sources/TabberInput/TextInserter.swift)).

Paste-and-restore remains the fallback for apps that ignore the Unicode payload. But since macOS 15.4, reading the general pasteboard can trigger a "Paste from Other Apps" permission alert. Code should check `NSPasteboard.accessBehavior` before snapshotting the clipboard ([Michael Tsai](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4)). Writing `kAXSelectedTextAttribute` is the least reliable path, because web editors and undo managers often never see the change ([WebKit bug 20997](https://bugs.webkit.org/show_bug.cgi?id=20997)). KeyType ships per-app overrides that choose among pasteboard paste, paste-and-match-style, character injection, chunked injection and first-word-only typing ([KeyType TextInsertion.swift](https://github.com/johnbean393/KeyType/blob/HEAD/Packages/TextInsertion/Sources/TextInsertion/TextInsertion.swift)). That mirrors the menu TabType attributes to Cotypist.

### A warm 2B base model meets a 200 ms budget only with cache reuse

llama.cpp is the proven runtime. It is MIT-licensed, ships a prebuilt Metal `llama.xcframework` for macOS 13.3+ ([Liquid AI docs](https://docs.liquid.ai/deployment/on-device/llama-cpp/mobile)), and gives direct control over KV state. The alternatives are weaker for this workload:

- **Ollama** roughly halved throughput against raw llama.cpp on an M4 Max (43.5 vs 89.4 tok/s) ([yage.ai](https://yage.ai/share/mlx-apple-silicon-en-20260331.html)).
- **MLX** decodes small models faster in secondary benchmarks, but its prefill and prefix-cache story is weaker. In one M1 Max anecdote, 94% of its time went to prefill ([yage.ai](https://yage.ai/share/mlx-apple-silicon-en-20260331.html)).
- **Apple's Foundation Models** is the worst fit. It runs at about 20–30 tok/s ([Apple Forums 791993](https://developer.apple.com/forums/thread/791993)), shares a 4,096-token context window ([Apple TN3193](https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md)), and is rate-limited "when your device is on battery AND when your process is running in the background" ([Apple Forums 789788](https://developer.apple.com/forums/thread/789788)). That is exactly the situation of an autocomplete agent.

The clones use small **base** models as raw continuers. Cotabby states it "treats the model as a pure text continuer rather than an instruction-tuned chat model." Its tiers are Qwen3.5-0.8B-Base at Q6_K (~0.8 GB), Qwen3.5-2B-Base at Q4_K_M (~1.4 GB), and Gemma 4 E2B and E4B at ~4.5 and ~5.0 GB ([Cotabby](https://github.com/FuJacob/cotabby)). The licensing landscape improved in 2026. Gemma 4 moved to **Apache 2.0** in April ([Implicator](https://www.implicator.ai/google-releases-gemma-4-under-apache-2-0-dropping-its-custom-ai-license/)). Qwen3.5's small models, including base versions, are Apache 2.0 ([Artificial Analysis](https://artificialanalysis.ai/articles/qwen3-5-small-models)). Qwen3-1.7B-Base covers 119 languages under Apache 2.0 ([Featherless/Qwen card](https://featherless.ai/models/Qwen/Qwen3-1.7B-Base/readme)). Llama 3.2 still carries a community license with attribution and a 700M-MAU clause ([Llama 3.2 card](https://huggingface.co/meta-llama/Llama-3.2-1b)). Small models also tolerate aggressive quantization worse than 7B-class models ([llama.cpp PR #4739](https://github.com/ggerganov/llama.cpp/pull/4739)), which argues for Q6_K or Q8_0 below about 1B parameters.

Latency comes down to arithmetic. On a base M1, llama.cpp ran a 7B Q4_0 model at about **118 tok/s prefill and 14 tok/s decode**; a base M4 reached about 221 and 24 ([llama.cpp discussion #4167](https://github.com/ggml-org/llama.cpp/discussions/4167)). Scaling down to a 1.7B Q4 model suggests about 50–85 tok/s decode and roughly a second to cold-prefill 512 tokens on a base M1. That estimate is mine, not a benchmark. A cold prompt is fatal at keystroke speed, so the context must already sit in the KV cache, with each keystroke prefilling only a handful of new tokens. That is the regime where a 10-token suggestion lands near Zed's targets of **under 200 ms at the median and under 500 ms at p90** ([Zed blog](https://zed.dev/blog/edit-prediction)).

The catch is architecture. Full-attention KV can be truncated back to a common prefix, but sliding-window layers (Gemma 4) and recurrent layers (Qwen3.5's Gated DeltaNet) overwrite state in place. llama-server then logs "forcing full prompt re-processing" unless a checkpoint covers the resume point ([particula.tech](https://particula.tech/blog/prompt-reprocessing-swa-hybrid-models-kv-cache)).

The other proven techniques come from code autocomplete, where llama.vim is the most transferable design ([llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)):

- **Typed-prefix cache.** If you type the next characters of a suggestion, the ghost text simply advances, with no inference.
- **Speculative prefetch.** The next suggestion is computed as if the current one were accepted.
- **Zero-token warm-up.** Requests with zero generated tokens pre-process new context.
- **Debounce with cancellation.** A 100 ms debounce, with each new request cancelling the old one.

Mid-word completion needs **token healing**: back off the final token and constrain the first generated token to start with the removed text ([Guidance docs](https://guidance.readthedocs.io/en/latest/example_notebooks/tutorials/token_healing.html); [Sweep](https://blog.sweep.dev/posts/token-healing-autocomplete)). KeyType implements this as "logit masking, trie admissibility, search" ([KeyType](https://github.com/johnbean393/KeyType)). For personalization, retrieval of past writing beats Apple's adapter route. Foundation Models adapters need a special entitlement, are tied to one system-model version, and the training toolkit "isn't compatible with macOS … 27 and later" ([Apple adapter page](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)).

## Nearly twenty Mac clones exist, but none is cross-platform or permissive at scale

Since April 2026 a wave of open-source Cotypist clones has appeared, and almost all are macOS-only Swift apps built on Accessibility, local base models and Tab-to-accept. Two lead:

- **Cotabby**: 1,084 stars, AGPL-3.0, last pushed October 15, 2026, 103 open issues. It has three engines: Apple Foundation Models, in-process llama.cpp and OpenAI-compatible endpoints. It installs via Homebrew, updates via Sparkle, claims "no analytics, no telemetry," and includes a Cotypist data importer.
- **KeyType**: 572 stars, MIT, last pushed August 29, 2026. It is split into SwiftPM packages for capture, prompting, model runtime, constrained generation, completion UI, text insertion and app compatibility ([Cotabby](https://github.com/FuJacob/cotabby); [KeyType](https://github.com/johnbean393/KeyType)).

Behind them is a long tail. TabType (47 stars, MIT, early alpha) has phrase beam search, token healing and encrypted history ([TabType](https://github.com/nilava/TabType)). AutoComp is Apache-2.0 ([AutoComp](https://github.com/ThalesMMS/AutoComp)). tabyrus is MPL-2.0, with a Swift frontend over a Rust backend ([tabyrus](https://github.com/semitechnological/tabyrus)). Tabber and Typist are MIT and only days old in October 2026 ([Tabber](https://github.com/chriscorbell/tabber); [Typist](https://github.com/BrodySalvucci/Typist)). Apart from the two leaders, every project has under 50 stars and a single maintainer, and several disclose heavy AI-generated code.

Windows and Linux are nearly empty. On Windows the options are prototypes:

- ghostype uses UI Automation with a cloud Claude backend ([ghostype](https://github.com/aixintan90/ghostype)).
- WinCotypist has no license.
- Frai AI-Keyboard prototypes a Text Services Framework IME with a separate AI daemon, also without a license ([AI-Keyboard](https://github.com/mdumr4/AI-Keyboard)).

On Linux the working pattern is an input-method addon, not an overlay. **Oma Tab** is an MIT Fcitx5 addon that "owns key routing, inline preedit, and deterministic acceptance." It uses a 120 ms debounce, aborts stale requests and pins model downloads to sha256, but it is tuned for one Arch-based distribution and has two stars ([omatab](https://github.com/r3dbars/omatab)). Wayland compounds the difficulty: even espanso's Wayland support is "experimental" and needs raw input-device access ([espanso Linux docs](https://espanso.org/docs/install/linux/)). No open-source project ships LLM ghost text on all three operating systems. The only multi-OS design found, SmartKey, is non-LLM, but its architecture is instructive: an Apache-2.0 Rust core holds the ghost-text state machine, with thin IBus, TSF and IMK adapters of 200–400 lines each ([SmartKey](https://github.com/RMANOV/smartkey)).

User demand is consistent. People want no word caps or subscription, local privacy, low latency and broad compatibility. Cotabby's open issues include "Makes my writing slower" ([#773](https://github.com/FuJacob/cotabby/issues/773)), "Cotabby makes typing laggy in Obsidian" ([#276](https://github.com/FuJacob/cotabby/issues/276)), Google Docs failures ([#660](https://github.com/FuJacob/cotabby/issues/660)), power-aware model switching ([#619](https://github.com/FuJacob/cotabby/issues/619)) and a target to "cut keystroke-to-ghost latency on the llama engine to under 60 ms" ([#875](https://github.com/FuJacob/cotabby/issues/875)). Once price is solved, the remaining complaints are about speed and per-app breakage, not missing features.

Licensing determines what can be reused:

| Project | License | Can its code go into a permissive project? |
|---|---|---|
| Cotabby | AGPL-3.0 | No. Its README warns that distributing a modified version obliges you to "provide the corresponding source code under the same license" ([Cotabby](https://github.com/FuJacob/cotabby)) |
| CotabbyInference (Cotabby's llama.cpp wrapper) | MIT | Yes |
| KeyType, Tabber, Typist, TabType | MIT | Yes, with notices retained |
| espanso (cross-platform key detection and injection crates) | GPL-3.0 | No, unless the whole project becomes GPL ([espanso](https://github.com/espanso/espanso)) |
| GhostType | PolyForm Noncommercial | No |
| stenotab, WinCotypist, AI-Keyboard | None | No, cannot legally be reused |

That leaves three realistic strategies. The first is to contribute to Cotabby: the largest community and the most heuristics, but the result is AGPL and macOS-only. The second is to fork KeyType: MIT, with package boundaries that mirror Cotypist's, but Swift end to end and seven weeks without a push. The third is to start a fresh repository that harvests MIT code. The next section argues for the third, with an important exception: if you only want a better Mac app, contribute to Cotabby rather than fork anything.

## Blueprint: a portable Rust core behind native shells

### Rust for the engine, Swift for the Mac surface

The deciding question is where the platform-independent intelligence lives. That intelligence is prompt assembly, KV-cache management, token healing, constrained decoding, suggestion caching, policy evaluation and personalization. Pure Swift is the fastest route to a Mac-only product, which is why every clone uses it. It also strands the hardest algorithmic work on one OS.

The recommendation is to put that work in a **Rust core**, compiled as a static library with a C ABI, and keep each OS surface native:

- **macOS:** Swift and AppKit. Rust's macOS Accessibility bindings are thin and slow-moving ([accessibility crate](https://github.com/eiz/accessibility)), while Swift has first-class access to `AXUIElement`, `CGEvent`, `NSPanel`, ScreenCaptureKit and Vision.
- **Windows:** Rust, using windows-rs and the actively maintained uiautomation crate ([uiautomation](https://github.com/leexgone/uiautomation-rs)).
- **Linux:** a C++ Fcitx5 addon first and an IBus engine second, linking the same core.

llama.cpp makes Rust a natural host: the llama-cpp-2 bindings are actively released (0.1.160 on October 15, 2026) ([llama-cpp-2](https://crates.io/crates/llama-cpp-2)). Settings and onboarding UI should be SwiftUI on macOS; Tauri 2 can serve Windows and Linux later ([Tauri](https://github.com/tauri-apps/tauri)). The ghost overlay itself must never be a webview, because it has to be click-through, non-activating, invisible to Accessibility and font-matched.

The core must be **renderer-agnostic**. It emits a suggestion state (a revision number, the text and its word boundaries) rather than pixels, because Windows TSF and Linux Fcitx5 render ghost text as inline preedit while macOS draws an overlay. Dependencies to avoid: rdev, whose last release was in 2023 ([rdev](https://crates.io/crates/rdev)), and espanso's GPL crates.

Inside the Mac app, four threads never wait on each other:

1. **Tap thread.** A CFRunLoop with an O(1) callback that reads a lock-free intercept state.
2. **AX thread.** A CFRunLoop that owns observers and polling, under an 80 ms global messaging timeout.
3. **Engine thread.** Owned by Rust; holds the llama context and a single sequence.
4. **Main thread.** Overlay and settings.

Every field snapshot carries a monotonically increasing revision. Any result whose revision is no longer current is discarded, following Cotabby's rule that "every async result can be stale" ([Cotabby ARCHITECTURE.md](https://github.com/FuJacob/cotabby/blob/main/ARCHITECTURE.md)).

### Twelve components, five of them portable

| Component | Responsibility | macOS implementation | Core or shell | Borrow from (license) |
|---|---|---|---|---|
| Capture (focus tracker) | Focused element, text window, caret index, marked range, role, size, secure flag, URL, window title | AX thread; per-pid `AXObserver`; post-keystroke re-read burst; 0.5 s idle poll with backoff; batched attribute reads; 4,000/1,000-unit window via `AXStringForRange`; text markers for web | Shell | Tabber FocusTracker/AXThread (MIT) |
| Web/Electron enabler | Make Chromium and Electron expose the AX tree and geometry | `AXManualAccessibility`, then guarded `AXEnhancedUserInterface` on the browser process; read back; re-assert on activation; skip when VoiceOver is running | Shell | Tabber WebAccessibility (MIT); Cotabby findings re-implemented clean-room |
| Caret resolver | Validated caret rect, line height, font | Zero-length bounds → previous character's edge → flip, scale and line repairs → text-run frame → mirror card; caches the winning strategy per app | Shell | Tabber CaretMath, FontResolver (MIT) |
| Context builder | Sectioned, token-budgeted prompt | Byte-stable header (app, field type, instructions), retrieved snippets, optional screen context, then text before the caret, truncated from the front at paragraph boundaries | **Core** | KeyType Prompting design (MIT) |
| Inference engine | KV reuse, token healing, constrained decoding, optional beam, personalization bias, cancellation | llama.cpp C API via Rust; Metal; one sequence; longest-common-prefix rollback; state snapshots for SWA/hybrid models | **Core** | llama.cpp (MIT); KeyType ConstrainedGeneration (MIT) |
| Suggestion session and cache | State machine (idle → pending → showing → accepting), type-through, LRU keyed by context hash, prefetch after accept | Rust, mirrored to an atomic intercept state read by the tap | **Core** | llama.vim design |
| Overlay | Ghost text, mirror card, numbered pickers | Borderless, non-activating, click-through `NSPanel`; all Spaces and full-screen; `setAccessibilityElement(false)`; Core Text at the resolved font, about 50% alpha | Shell | Tabber GhostPanel (MIT) |
| Key tap | Observe typing; consume Tab, accept-all and Esc only while a suggestion is visible | Permanent listen-only session tap, plus a head-inserted `.defaultTap` installed only while visible; synthetic-event marker; re-enable on timeout; 50 ms delayed teardown; Secure Input detection | Shell | Tabber KeyboardMonitor (MIT); Cotabby two-tap idea |
| Inserter | Commit accepted text | Unicode `CGEvent`s of ≤20 UTF-16 units with key code 0 and Return for newlines, posted to `.cgAnnotatedSessionEventTap`; per-app paste-and-restore only when `accessBehavior` allows; transient pasteboard marker | Shell | Tabber TextInserter (MIT); KeyType TextInsertion (MIT) |
| Per-app policy and compatibility DB | Default on/off, idle rules, AX priming, caret and insertion strategy, Esc mode, agent-prompt patterns | Declarative data keyed by bundle ID plus URL pattern; signed; updated independently of app releases | **Core** (data) | KeyType DefaultOverrides (MIT) |
| Settings and personalization | Length presets, instructions, model manager, opt-in history, frequency profile, retrieval, strength slider | SwiftUI; encrypted SQLite with the key in the Keychain; profile drives a logit bias | **Core** plus shell UI | — |
| Screen context (optional) | OCR of the surrounding window | ScreenCaptureKit window capture, then Vision `VNRecognizeTextRequest`; exclude own windows; memory-only cache | Shell | Tabber WindowCapture; Typist ScreenContext (MIT) |

The policy layer deserves the most investment because it is the part Cotypist charges for. Each app entry should encode:

- whether the app is enabled by default (terminals, code editors, password managers and remote desktops start off);
- the minimum field size;
- which AX priming flag to use;
- the order in which to try caret strategies;
- the insertion strategy (keystrokes, per character, chunks, paste, paste-and-match-style, or first word typed then paste);
- a font offset;
- regular expressions for detecting agent prompts in terminals.

Publish this database under **CC0** in its own repository, so every clone, AGPL Cotabby included, can share and improve one commons instead of maintaining four private catalogs. Today Cotabby, KeyType, Pretype and AutoComp each keep their own ([Cotabby #626](https://github.com/FuJacob/cotabby/issues/626)).

The policy gate runs before any inference. It blocks secure fields, detected through role, subrole and role description; Cotabby notes that CVV and OTP fields never say "password" ([Cotabby SecureFieldDetector.swift](https://github.com/FuJacob/cotabby/blob/HEAD/Cotabby/Support/Accessibility/SecureFieldDetector.swift)). It also blocks while Secure Event Input is active, while a marked range is present, and when more than about eight characters follow the caret on the line, unless mid-line completion is enabled. The eight-character threshold is llama.vim's `max_line_suffix` ([llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)). Finally, it blocks when the partly typed word cannot become a dictionary word, the gate TabType attributes to Cotypist.

### Qwen3 base models by default, Gemma 4 once state snapshots land

| Tier | Model | License | Quant (approx. size) | Why |
|---|---|---|---|---|
| Light, 8 GB Macs | Qwen3-0.6B-Base | Apache-2.0 | Q8_0 | Dense full attention; small models lose quality under heavy quantization |
| **Default** | **Qwen3-1.7B-Base** | Apache-2.0 | Q4_K_M–Q5_K_M (~1.1 GB weights, estimated) | Dense, so KV rollback is a simple truncation; 119 languages |
| Quality, 16 GB+ (auto-selected) | Qwen3-4B-Base | Apache-2.0 | Q4_K_M (~2.5 GB) | Beat Cotypist's own model file on characters saved (1.46 vs 1.17). Ran at 148 ms against Gemma 4 E4B's 217 ms in TabType's runtime ([TabType README](https://github.com/nilava/TabType)) |
| Multilingual, Phase 3 | Gemma 4 E2B / E4B base | Apache-2.0 since April 2026 | Q4_K_M–Q6_K (~4.5–5.0 GB) | Cotypist's default. Per-layer embeddings keep resident memory low, but the sliding-window layers need state snapshots or `--swa-full` |
| Experimental | Qwen3.5-0.8B / 2B-Base | Apache-2.0 | Q6_K / Q4_K_M (~0.8 / 1.4 GB) | Better quality per byte, but recurrent layers need checkpointed state |
| Not a default | Llama 3.2; Gemma 3 | Community license; Gemma Terms | — | License obligations; Apache alternatives exist |

The MVP should support only dense, full-attention models. This keeps a single, simple cache path (truncate to the common prefix, prefill the delta) until a snapshot-and-restore path for hybrid and sliding-window models is built and measured.

Download models on first run from Hugging Face with sha256 pinning, as Oma Tab does, and never bundle them in the DMG. Choose the default tier from installed RAM and chip class. Keep the runtime pluggable behind one trait:

- in-process llama.cpp (default);
- an OpenAI-compatible HTTP backend, preferring raw `/completion` over chat endpoints, for llama-server, Ollama, LM Studio or a cloud provider, off by default with keys in the Keychain;
- Apple Foundation Models as an optional zero-download fallback that is never the default;
- MLX as a later experiment, once its prefix-cache trimming is validated.

### Latency comes from never recomputing what you already know

The targets below are design goals for a warm cache on a base M1-class Mac. They sit inside Zed's 200/500 ms targets and point toward Cotabby's sub-60 ms ambition.

| Stage | Target | Technique |
|---|---|---|
| Typed character matches the ghost text | One frame, zero inference | Advance the ghost; shift it by the width of consumed characters while AX catches up |
| Keystroke → field snapshot | ≤20 ms typical, 80 ms hard ceiling | Post-keystroke re-read burst; batched attributes; bounded text window |
| Prefill | 1–10 new tokens | Byte-stable header; front truncation in coarse jumps; longest-common-prefix rollback; restore the pre-generation state |
| Keystroke → first visible word | p50 ≤120 ms, p90 ≤300 ms | Constrained first token, streamed word by word into the overlay |
| Full 2–7-word suggestion | Hard wall-clock cap of ~250 ms | Show whatever whole words exist at the cap; stop on newline or sentence end |
| Focus or field change | Off the critical path | Zero-token prefill of header, retrieved snippets and screen context |

Scheduling should follow Cotypist's reported choice of **no fixed debounce** on mains power: each keystroke cancels the in-flight job through an abort flag checked between decode steps, and at most one request is ever pending. The clones mostly use fixed waits (Typist 120 ms, Oma Tab 120 ms, stenotab 45 ms) ([Typist ARCHITECTURE.md](https://github.com/BrodySalvucci/Typist/blob/HEAD/docs/ARCHITECTURE.md); [stenotab](https://github.com/mia-cx/stenotab)). On battery or under thermal pressure, add a 60–100 ms debounce and fire immediately only at word boundaries.

KV reuse depends on keeping the prompt prefix byte-identical. Window titles, retrieved snippets and screen text should change only on focus changes, and the front of the before-caret text should move at paragraph boundaries rather than per character. For mid-word input, the engine should:

1. split the text into a committed prefix and a fragment;
2. back off the trailing tokens until the fragment is covered;
3. mask logits during the first decode steps to tokens consistent with the fragment, using a vocabulary trie built once per tokenizer;
4. display only the characters beyond what the user typed.

Once a suggestion is visible, prefetch the continuation as though it were accepted, so repeated Tab presses feel instant.

Keep weights memory-mapped and resident while the user types. Unload them after a few idle minutes, as Cotypist does, and load dictionaries and tries in the background: TabType cut its first suggestion from about 2.2 s to about 240 ms by moving the dictionary load off the critical path ([TabType README](https://github.com/nilava/TabType)). Start the MVP with greedy decoding plus the constrained first word. Add a phrase beam of 3–9 in Phase 3, behind a measurement harness, because beams trade energy for quality.

### Apache-2.0, a fresh repo, and harvested MIT code

**License the core and shells under Apache-2.0**, dual MIT/Apache-2.0 for the Rust crates per ecosystem convention, and the compatibility database under CC0. There are four reasons:

1. The clearest unfilled gap is a permissive project at community scale; the largest existing one is AGPL.
2. MIT code from KeyType, Tabber, Typist and TabType can be incorporated with its notices kept.
3. Apache-2.0 adds an explicit patent grant, which matters in a field that touches input methods and machine learning.
4. Apache-2.0 code can flow into GPLv3 and AGPLv3 projects, so Cotabby could adopt the core or the database without a license conflict.

The strongest counter-argument is that AGPL prevents closed commercial forks while a dozen paid rivals circle. But the durable value of an open project here is shared data and community velocity, not secrecy, and a copyleft core would block the embedding that makes a portable engine worth building. Do not copy Cotabby source. Study its documented findings and re-implement them clean-room. Verify each borrowed file's LICENSE rather than trusting summaries; one research pass for this report mislabeled Cotabby as MIT.

**Start fresh rather than fork.** Forking KeyType means inheriting a Swift-only architecture that would have to be dismantled to extract a portable core. Forking Cotabby means AGPL, a macOS lock-in, and fragmenting the most active community. Instead, create a new repository with the Rust core and port the macOS shell from **Tabber**, which has the cleanest module boundaries (`TabberAX`, `TabberInput`, `TabberOverlay`, `TabberContext`), live verification on macOS 27, a notarization script and a Sparkle-on-GitHub-Releases pipeline ([Tabber architecture.md](https://github.com/chriscorbell/tabber/blob/HEAD/docs/architecture.md)). Seed the compatibility database from KeyType's per-app overrides and its insertion-strategy taxonomy. Tabber is days old with no community, so treat its code as a well-commented starting point, not proven software. If the goal narrows to a Mac-only app, abandon this plan and contribute to Cotabby.

### Ship a notarized, unsandboxed DMG with Sparkle

Mac App Store distribution is effectively ruled out. Cross-app Accessibility control, global event taps and posting events into other apps are incompatible with the App Sandbox, and every clone disables it ([Tabber entitlements](https://github.com/chriscorbell/tabber/blob/HEAD/App/Tabber.entitlements)). The release build should be:

- signed with a Developer ID, with hardened runtime;
- notarized with `notarytool` and stapled;
- a menu-bar agent (`LSUIElement`) with an `NSAccessibilityUsageDescription`;
- updated through Sparkle with an EdDSA-signed appcast on GitHub Releases;
- also offered as a Homebrew cask, as Cotabby does.

Statically link llama.cpp into the Rust core. KeyType had to set `disable-library-validation` to load a dynamic llama.cpp framework under hardened runtime ([KeyType entitlements](https://github.com/johnbean393/KeyType/blob/HEAD/KeyType/KeyType.entitlements)), and static linking avoids that weakening. Sign even local development builds with a stable identity, because ad hoc signing "makes macOS re-ask for Accessibility after each rebuild" ([Typist README](https://github.com/BrodySalvucci/Typist)).

Onboarding should ask only for Accessibility up front. Screen Recording is opt-in, since macOS 15 re-prompts for it monthly ([TidBITS](https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly)). Whether the listen-only tap works under the Accessibility grant alone should be tested on macOS 14 through 27, with Input Monitoring requested only if it does not. Poll `AXIsProcessTrusted()` and tear down the active tap the moment trust disappears, to avoid the revocation freeze. Ship with telemetry off and no network traffic beyond model downloads and update checks. An offline-verification switch, as Shadowtype offers, turns Cotypist's on-by-default analytics into a visible point of difference ([Shadowtype](https://github.com/dario-valles/shadowtype)).

### Six phases from Mac MVP to Linux

| Phase | Rough duration (2–3 engineers, estimate) | Scope | Exit criteria |
|---|---|---|---|
| 0. Spikes and evaluation harness | 2 weeks | Probe CLI for AX reads, caret rects and taps across 15 target apps; `llama-bench` of Qwen3 0.6B/1.7B/4B on base M1 and M4; replay-based eval measuring characters saved per accept (TabType's metric), latency and energy | Measured AX latency per app; warm-cache p50 known per model and chip |
| 1. Mac MVP | 6–8 weeks | AX thread; caret resolver plus mirror card; ghost panel; two-tap key design; Unicode insertion; Tab, accept-all, Esc and Option+Tab; secure-field, secure-input and marked-text guards; type-through; prefix rollback; token healing; Qwen3-1.7B; menu bar; per-app denylist | p50 ≤150 ms warm on base M1; works in TextEdit, Notes, Mail, Messages, Safari and Chrome; zero dropped user keystrokes in a 10,000-keystroke soak test |
| 2. Compatibility breadth | 6 weeks | Chromium/Electron priming with read-back; text markers; font resolver; per-app insertion strategies; paste fallback gated on pasteboard privacy; idle rules; terminal agent-prompt detection; force-activate and snooze hotkeys; CC0 compatibility DB v1 covering 30 apps | Parity with every app Cotypist's compatibility page lists as "works" |
| 3. Quality and personalization | 6 weeks | Length presets (2/4/7/10 words); custom instructions as prompt header; opt-in OCR context; speculative prefetch; phrase beam; encrypted history, frequency-profile logit bias and per-app retrieval; Gemma 4 via state snapshots; emoji; autocorrect; Cotypist history import | Characters saved per accept on the project's public eval set meets or beats the Phase 0 Qwen3-4B baseline |
| 4. Public 1.0 | 3–4 weeks | Notarized DMG, Sparkle, Homebrew cask, hardware-tiered model manager, BYO backends, Foundation Models fallback, docs, eval in CI | Signed releases; reproducible eval numbers published with each release |
| 5. Windows | 8–12 weeks | Rust shell: UIA `TextPattern2::GetCaretRange` ([Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationtextpattern2-getcaretrange)); low-level keyboard hook; topmost layered overlay; `SendInput` Unicode, following ghostype's capture chain; GPU and CPU llama.cpp builds; later a TSF text service split into a lean in-host DLL and an engine process, per Frai's design | Works in Notepad, Word, Outlook, Chrome, Edge and Teams |
| 6. Linux | 8 weeks | Fcitx5 addon with preedit ghost text and deterministic acceptance (Oma Tab pattern), then an IBus engine; AT-SPI context through the atspi crate where available; Wayland first | Packaged for at least two distributions; works in GTK, Qt and Chromium fields under Wayland |

The roadmap front-loads measurement for a reason. No published evaluation compares small base models on prose continuation, and Cotypist publishes no latency figures. A replay harness that reports characters saved, acceptance and p50/p90 latency on every commit would be the project's sharpest tool. It would also give a community something a solo developer cannot match.

## Conclusion

Cotypist turns out to be a polished set of compatibility workarounds wrapped around a commodity model. Its default weights are off-the-shelf Gemma, and an outside test found them beaten on keystroke savings by an equally off-the-shelf Qwen3 base model. What the subscription actually pays for is the slow, app-by-app work of knowing where the caret really is and when to stay quiet. The open-source clones have rediscovered that knowledge separately and stored it in four incompatible private catalogs. The highest-leverage move for a free equivalent is therefore social as much as technical: make per-app compatibility a shared, permissively licensed dataset with a public evaluation harness, so a hundred contributors can outpace one developer at the very thing he charges for.

The second implication concerns architecture. On macOS the overlay-plus-event-tap design is mandatory, but on Windows and Linux the input-method frameworks (TSF, Fcitx5, IBus) offer cleaner, more reliable paths that render ghost text as preedit inside the host. An engine that emits suggestion state instead of pixels is what makes one project viable on all three platforms. Apple's own moves point the same way. macOS 27's Foundation Models framework now accepts third-party models, and Core AI promises first-party on-device runtimes ([Apple, What's new in macOS 27](https://developer.apple.com/macos/whats-new/)), so the inference layer will keep commoditizing. Durable value will sit in the policy data, the latency engineering and the cross-platform reach, which are exactly the parts a closed, Mac-only, solo-maintained product is worst placed to build.
