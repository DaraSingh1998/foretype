# Cotypist (cotypist.app): Product Profile

Research date: 2026-10-18. Web research only; no binaries were downloaded or run. Labels: "Official" means cotypist.app pages or the developer's own statements; "Press/user" means third-party reporting; "Inference" means my own reasoning. Dates are given wherever a source is older than the current official site.

## 1. What Cotypist does: display, accept/dismiss, shortcuts, settings

### Takeaway
Cotypist is a closed-source, freemium macOS menu-bar app. It watches the focused text field in other apps through the macOS Accessibility APIs and draws gray inline "ghost text" at the caret, in the field's own font, predicting the next few words. **Tab accepts one word at a time**, the key above Tab (` / § / ^) accepts the whole suggestion, Esc dismisses it and briefly pauses suggestions, and you can simply keep typing to ignore it. Beyond basic completion, settings cover completion length, per-app/per-domain enablement and instructions, global custom instructions, a personalization slider, model choice, emoji shortcodes, inline autocorrect, and "Labs" features (word alternatives, synonyms, mid-line completion, clipboard awareness, Mac sync).

### Cited Findings
**Core behavior and display**
- Official tagline: it "predicts your next words in every Mac app," running "on your Mac, not in the cloud." Suggestions appear inline in the app you're using. Keep typing to override, and suggestions usually re-align "within a letter or two." — [cotypist.app](https://cotypist.app)
- Press: it suggests a few words ahead of the insertion point; Tab accepts, and continuing to type ignores the suggestion. Suggestions appear inline in any app, in the current font, through macOS accessibility APIs. — [Daring Fireball, 2026-06-18](https://daringfireball.net/linked/2026/06/18/cotypist)
- User report: suggestions appear as gray inline text next to the cursor. — [Sir Apfelot, 2025-12-14](https://www.sir-apfelot.de/cotypist-68457/); [Nicolas Deville notes, 2026-05-31](https://notes.nicolasdeville.com/apps/cotypist/)
- Official: suggestions update after every keystroke, and typing a letter or two refines a near-miss. "The first word or two of a suggestion tend to be most reliable." It works best on substantive writing. — [Help: Tips](https://cotypist.app/help/tips)
- Official FAQ: it is not a ChatGPT replacement. It saves time by suggesting words you would type anyway, accuracy improves with longer texts, and it is "not perfect." — [cotypist.app FAQ](https://cotypist.app/?terminal=1)
- Official: "Cotypist intentionally stays idle in small text fields." Use force-activate there. A brand-new empty field may wait for a few words before suggesting. — [Help: Troubleshooting](https://cotypist.app/help/troubleshooting)
- Official: when an app doesn't expose an inline position (Firefox, Zen Browser, and Arc/Dia without a workaround), suggestions appear in a "mirror" window above the text field instead of inline. — [Compatibility](https://cotypist.app/compatibility); [Troubleshooting](https://cotypist.app/help/troubleshooting)
- Official: a small Cotypist icon appears next to text fields and offers per-app toggles (enable, recording). The menu bar icon offers the same toggles and shows model download progress. — [Help: Tips](https://cotypist.app/help/tips); [Help: Personalization](https://cotypist.app/help/personalization); [Troubleshooting](https://cotypist.app/help/troubleshooting)
- Official: inserting longer completions may briefly use the clipboard, and Cotypist tries to restore the original contents afterward. — [Help: Privacy](https://cotypist.app/help/privacy)
- Press (2025-03): it respects the Mac's Smart Quotes preferences. — [MacSparky sponsor post, 2025-03-03](https://www.macsparky.com/blog/2025/03/cotypist-ai-autocompletion-everywhere-on-your-mac/)

**Keyboard shortcuts (official current defaults)** — [Help: Shortcuts](https://cotypist.app/help/shortcuts)
- **Tab**: complete the next word ("the main shortcut"). Repeated presses step through the suggestion word by word.
- **Key above Tab (` / § / ^, layout-dependent)**: accept the full suggestion. It may be unassigned on some layouts.
- **Esc**: dismiss the suggestion. By default this also pauses completions in that field for a few seconds, and a second Esc passes through to the app. Esc behavior is configurable: "Pause briefly" (default), "Turn completions off in the current app until you switch apps," or "Leave Esc alone."
- **Ctrl+`**: force-activate completions in fields where Cotypist stays idle (terminals, small fields, code editors).
- **Ctrl+Option+Cmd+`**: toggle completions in the current app off or on for a few minutes.
- **Global toggle**: unassigned by default. When set, it disables completions everywhere until pressed again.
- **Option+Tab**: sends a regular Tab through. So does Esc followed by Tab. The Tab shortcut can be disabled per app or globally while keeping the key-above-Tab shortcut.
- All shortcuts can be changed in a Shortcuts settings pane with recorder fields. On non-US layouts the physical key is what counts, even if the label displays differently.
- Option: "Include trailing space after single-word completions" (added in v0.17.1, December 2025). — [Help: Shortcuts](https://cotypist.app/help/shortcuts); [MacUpdater 0.17.1 notes](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html)
- Conflict between official pages: the Tips page says the whole-suggestion key is "unassigned by default" — [Help: Tips](https://cotypist.app/help/tips) — while the Shortcuts page lists `/§/^ as the default — [Help: Shortcuts](https://cotypist.app/help/shortcuts). A December 2025 user reports "^" (German layout) accepting the full suggestion by default — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/). In March 2025, both keys were user-defined (the reviewer used backtick for full and Tab for next word) — [MacSparky 2025-03-03](https://www.macsparky.com/blog/2025/03/cotypist-ai-autocompletion-everywhere-on-your-mac/).
- Homepage wording conflicts slightly: one section says Tab takes "the next word or the whole line," while the FAQ says Tab inserts just the next word. — [cotypist.app](https://cotypist.app)

**Settings and features**
- Completion length ("Complete Settings") runs from 1–2 words up to "Very Long" (10–15 words). On an M1 Max, "Very Long" sometimes took about 2 seconds. — [Sir Apfelot, 2025-12-14](https://www.sir-apfelot.de/cotypist-68457/). Free tier is locked to the default short length, and Plus/Pro can configure it. — [Pricing](https://cotypist.app/pricing)
- Global Custom AI Instructions: a short free-text note about you (occupation, writing types, style), used "when generating every suggestion." It is pre-filled from the Mac's language/region and has a "Reset to Default" button. Per-app/per-domain instructions are appended after the global ones. Apps are added by dragging them onto a list, and domains are added manually. — [Help: Personalization](https://cotypist.app/help/personalization)
- Per-app/per-domain examples: German instructions for email and English for Slack, different tone per context, recording disabled for sensitive apps. — [Help: Tips](https://cotypist.app/help/tips)
- "Personalize word choice" slider: Off / Low to Medium / Strong. "Strong" can override a better word in favor of a frequently used one. — [Help: Personalization](https://cotypist.app/help/personalization). The pricing page implies 6 ticks: Free up to the 2nd ("Gentle"), Plus up to the 4th (default, "Balanced"), Pro up to the 6th ("Max"). — [Pricing](https://cotypist.app/pricing)
- Emoji: type a colon followed by a shortcode and pick from options. — [cotypist.app](https://cotypist.app). Since v0.17.1, numpad keys select emoji options, and emoji completion is disabled in apps with their own emoji pickers (Slack, Notion, GitHub). — [MacUpdater 0.17.1](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html)
- Typos: inline typo correction, applied with Tab. — [cotypist.app](https://cotypist.app). Inline autocorrect arrived in v0.22 (around late May 2026). — [MacSparky 2026-05-28](https://www.macsparky.com/blog/2026/05/cotypist-brings-smart-autocomplete-to-every-mac-app/). The Free tier gets only a typo indicator, while Plus gets "full autocorrect." — [Pricing](https://cotypist.app/pricing). The developer says its current-word autocorrect "can fire as soon as a wrong letter is typed" and recommends turning off macOS autocorrect. — [Product Hunt launch page](https://www.producthunt.com/p/cotypist/cotypist-2). Conflict: the Tips page still says Cotypist "extends text but does not modify it" and doesn't correct spelling or grammar, which is probably stale text from before 0.22 — [Help: Tips](https://cotypist.app/help/tips).
- Labs (Pro, early access), from the help docs:
  - Word Alternatives: a numbered list below the cursor of other words the model considered. Press a number to insert one. Off by default. Appears after a short pause or on a shortcut.
  - Synonyms for selected words: select a word or phrase, get context-fitting synonyms, and press a number to replace it. On by default (for Labs users). Trigger is configurable: after selecting, after a brief pause, or on shortcut.
  — [Help: Tips](https://cotypist.app/help/tips)
- Other Pro/Labs items: mid-line completion, clipboard awareness, per-app instructions, Mac sync. — [Pricing](https://cotypist.app/pricing). The v0.22 Labs section added mid-line completions, British English, and right-to-left support for Arabic and Hebrew. — [MacSparky 2026-05-28](https://www.macsparky.com/blog/2026/05/cotypist-brings-smart-autocomplete-to-every-mac-app/)
- Statistics show words completed per active day. — [Help: Tips](https://cotypist.app/help/tips). One user averaged 100–200 completed words per day. — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)
- Model picker in "AI Settings": recommends a model for your Mac, and the model downloads in-app with one click. — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/); [Nicolas Deville](https://notes.nicolasdeville.com/apps/cotypist/)
- App Settings > Troubleshooting > "Improve Compatibility With This App" is the official top fix for apps that don't show completions. — [Troubleshooting](https://cotypist.app/help/troubleshooting)
- Floating button offering to enable Google Docs accessibility mode automatically. — [Compatibility](https://cotypist.app/compatibility)
- "Mac feeling slow?" note in the menu, which blames leaked event taps from other apps. — [Troubleshooting](https://cotypist.app/help/troubleshooting)
- Languages: works best in English and supports many others. Norwegian and Hinglish are mentioned, and switching languages mid-sentence is supported. — [cotypist.app](https://cotypist.app); [Press kit](https://cotypist.app/press)

### Inferences
Clone feature checklist (user-visible behaviors to match), derived from the findings above:
- Inline ghost text matching the host field's font, plus a mirror/overlay window fallback when caret geometry isn't available.
- Per-keystroke regeneration, with "type-through": if the typed char matches the suggestion's next char, keep the suggestion instead of regenerating.
- Tab inserts the next word. A separate key accepts all. Option+Tab passes through a real Tab.
- Esc dismisses and pauses per field, with 3 configurable modes. A second Esc passes through.
- Force-activate hotkey, a per-app temporary disable (a few minutes), and a global toggle.
- Idle heuristics: small fields, password/secure fields, code editors' main editor, terminal shell prompts (except AI-agent prompts), Google Sheets cells.
- Per-app and per-domain settings (browser URL awareness), a floating per-field icon, and a menu-bar status with model-download progress.
- Completion-length presets (1–2 words up to 10–15 words), global and per-app instructions, an optional local typing-history personalization with a strength slider, and an encrypted local store with delete controls.
- Emoji :shortcode picker with number selection, inline autocorrect of the current word, and an optional trailing space after single-word accepts.
- Restore the clipboard after paste-based insertion, and respect the Smart Quotes setting.
- The developer's emphasis on handling Secure Input, Tab conflicts with Grammarly/TextExpander/Karabiner, and duplicate-instance detection suggests these are real failure modes a clone will hit.

### Gaps
- No official numeric latency figure. Implicator cites a "100–200 ms" prediction window, but it's unclear where that figure comes from ([Implicator, 2026-01-01](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)). A Product Hunt user asked about latency, and the developer's answer wasn't visible.
- How ghost text is rendered technically (overlay window vs. text injection) is not documented officially beyond "accessibility APIs" and "current font."
- No official full list of supported languages.

## 2. AI models, local vs. cloud, hardware requirements, personalization

### Takeaway
Inference is fully on-device via llama.cpp (officially stated in the press kit) with open-weight models. The 2026 default is **Google Gemma 4 E2B**. The Pro tier unlocks larger models up to Gemma 4 26B-A4B and Qwen 3 30B-A3B. The app requires Apple Silicon and macOS 14+, recommends M1 Pro/M2 with 16 GB RAM, and uses about 1–2.5 GB of RAM while active. The model catalog has changed repeatedly: Gemma 3 was the default in late 2025, Ministral 3B was added in December 2025, and Qwen 2.5 1.5B was reported as primary by one source in January 2026. Personalization is an opt-in local typing-history store that feeds a "derived personalization profile." The method (fine-tuning vs. retrieval/prompting) is undisclosed.

### Cited Findings
- Official press kit: runs on-device via llama.cpp with Gemma 4 as the default model. One section mentions a "3 GB Gemma model," and RAM use is roughly 1–2.5 GB. Works offline, with no cloud calls or API. Distributed as a notarized direct DMG with auto-updates. — [Press kit](https://cotypist.app/press)
- Official current model catalog (pricing page) — [Pricing](https://cotypist.app/pricing):
  - Free and Plus, light models: Gemma 4 E2B, Qwen 3 1.7B, Gemma 3 1B.
  - Free and Plus, mid-size models: Gemma 4 E4B, Qwen 3 4B, Gemma 3 4B.
  - Pro adds: Gemma 4 26B A4B, Qwen 3 30B-A3B, Qwen 3 8B.
- Developer (Product Hunt, around June 2026): the default is Gemma 4 E2B. It's "a few GB on disk" but needs only about 1 GB of active memory "because weights are streamed from disk as needed." On M-series Max/Ultra, E4B (about 2.5 GB in memory) gives better suggestions. The model unloads and frees memory when you're not typing. — [Product Hunt](https://www.producthunt.com/products/cotypist)
- Developer: the first suggestion after an idle pause can be slower, which he calls "usually acceptable." — [Product Hunt launch page](https://www.producthunt.com/p/cotypist/cotypist-2)
- Official hardware: Apple Silicon only (no Intel), macOS 14 or later. Recommended: M1 Pro or M2 or higher with 16 GB RAM. Active memory use is about 1–2.5 GB. Completions appear "almost instantly" on recommended specs. Energy use is acknowledged as potentially high, with optimization ongoing. — [cotypist.app](https://cotypist.app); [FAQ](https://cotypist.app/?terminal=1)
- MacUpdater metadata lists the minimum OS as macOS 14.6 for v0.17.1. — [MacUpdater](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html)
- Historical model catalog (December 2025, beta) — [Sir Apfelot, 2025-12-14](https://www.sir-apfelot.de/cotypist-68457/):
  - Default was Gemma 3, about 2.3 GB.
  - Smaller Gemma variants of about 0.8 GB and 0.3 GB, for 8 GB Macs.
  - SmolLM, about 1.8 GB.
  - Qwen models mainly for English, the largest about 13.7 GB and sensible only with 32 GB+ RAM.
  - The model stayed loaded in memory, CPU load was low, and it mostly used the GPU.
- v0.17.1 (2025-12-23) added support for the Ministral 3B model. — [MacUpdater](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html)
- Conflicting report: Implicator (2026-01-01) says the "primary model is Qwen 2.5 1.5B, chosen for speed on Apple Silicon." This conflicts with Sir Apfelot's Gemma 3 default two weeks earlier; Implicator may be summarizing older site text. — [Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
- A user warns that choosing a heavy model that can't keep up with typing makes the experience worse. — [Nicolas Deville](https://notes.nicolasdeville.com/apps/cotypist/)
- Personalization (official):
  - "Record your writing for personalization" is off by default. When on, it records text typed in active fields.
  - Default mode records "only when you accepted a completion." An optional toggle records every monitored text.
  - Short texts are never recorded, which skips search queries and quick form entries.
  - The data feeds a "derived personalization profile." Deleting the data reverts suggestions to "unmodified model behavior."
  — [Help: Personalization](https://cotypist.app/help/personalization)
- Developer: it learns your voice locally using "a mix of global and context-specific adaptation," learns "from your writing in each app over time," and adapts quickly to the current conversation's style. — [Product Hunt](https://www.producthunt.com/products/cotypist); [PH launch page](https://www.producthunt.com/p/cotypist/cotypist-2)
- In December 2025 the developer described personalization ("Collect Inputs for Personalization") as rudimentary. — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)
- Context: an optional Screen Recording permission lets it read surrounding on-screen text. Screenshots are processed locally and "never stored or sent anywhere." — [Help: Privacy](https://cotypist.app/help/privacy). A user found suggestions noticeably worse without Screen Recording. — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/). Tao of Mac (2026-04-11) notes it "uses screenshot-derived context." — [Tao of Mac](https://taoofmac.com/space/apps/cotypist)
- Clipboard awareness (Pro) is optional and off by default. Clipboard content is "read in memory only." — [Help: Privacy](https://cotypist.app/help/privacy); [Pricing](https://cotypist.app/pricing)
- Product Hunt "Built with" lists Claude Code, Paddle, and Hugging Face. — [Product Hunt](https://www.producthunt.com/products/cotypist)

### Inferences
- "Weights streamed from disk" plus "about 1 GB active for a few-GB model" is consistent with llama.cpp mmap'd GGUF weights, where only touched pages are resident. Gemma 4 E2B's per-layer-embedding architecture would also make this cheaper. This is my inference from the developer's description.
- Use of base or instruct models is unstated. A "derived personalization profile" with instant reset is more consistent with prompt-side conditioning (vocabulary/phrase lists, few-shot snippets, or logit biasing toward frequent words) than with on-device fine-tuning. The slider language ("can override a more fitting word in favor of a frequently used one") strongly suggests a token-level logit bias toward the user's frequent words. This is inference, not confirmed.
- Screen context appears to be screenshot → OCR → text injected into the prompt. Official wording is "captures nearby text, not images," and the open-source clone Cotabby explicitly uses screenshot OCR.

### Gaps
- No official statement of quantization levels, context window size, prompt format, or whether base or instruct checkpoints are used.
- Download sizes for the current Gemma 4 / Qwen 3 catalog aren't published officially. The "3 GB Gemma" figure comes from the press kit.
- No official latency/tokens-per-second benchmarks.
- Personalization algorithm undisclosed.

## 3. Privacy and data handling

### Takeaway
The official claim is that all inference runs locally and typed text never leaves the Mac. Cotypist reads only the focused field via Accessibility, plus optional OCR'd screen text and clipboard, all processed in memory. Personalization recording is opt-in and stored encrypted, with the key in the macOS Keychain. Optional iCloud sync is end-to-end encrypted via iCloud Keychain. **Anonymous usage statistics and crash reports are on by default** (Sentry and Google BigQuery, both in Frankfurt) and can be opted out. License validation and update checks also contact servers.

### Cited Findings
- Official: "The AI that generates suggestions runs locally on your device." Typed text is not sent to Cotypist: "we have nothing to send even if we wanted to." — [Help: Privacy](https://cotypist.app/help/privacy)
- Official: Accessibility "Lets Cotypist read the text field you are actively typing in." "Password fields are automatically blocked by macOS." — [Help: Privacy](https://cotypist.app/help/privacy)
- Official: Screen Recording (optional) captures nearby text, not images. "Screenshots themselves are never stored or sent anywhere." — [Help: Privacy](https://cotypist.app/help/privacy)
- Official: clipboard reading is optional and off by default. "Clipboard content is read in memory only. Nothing is stored, and nothing is transmitted." — [Help: Privacy](https://cotypist.app/help/privacy)
- Official: typed-text recording for personalization defaults to Off. When on, it is "Encrypted on your Mac, with the key in the macOS Keychain," with per-app/per-domain controls and bulk or per-app deletion. The derived profile is "Encrypted, on your Mac only" and "never synced." — [Help: Privacy](https://cotypist.app/help/privacy); [Help: Personalization](https://cotypist.app/help/personalization)
- Official: iCloud sync is optional and off by default. Data goes to "Your own iCloud account, never ours." Each text is encrypted on the Mac with a key shared via iCloud Keychain. Synced data includes typed text plus the app, window title, and web address. Screenshots, per-app settings, and stats are not synced. — [Help: Privacy](https://cotypist.app/help/privacy)
- Official: anonymous usage statistics and crash reports are **on by default**. Crash reports go to Sentry (Frankfurt), and usage counts go to Google BigQuery (Frankfurt). This never includes "the text you typed, your clipboard contents, or anything recognized from screen content." Opt out under Settings > General > Privacy ("Share anonymous usage statistics and crash reports"); the change takes effect after restart. — [Help: Privacy](https://cotypist.app/help/privacy)
- Press: licensing data goes to servers for validation and update checks. — [Implicator, 2026-01-01](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
- Official: no account required to install. A "Works offline" label appears on the homepage. — [cotypist.app](https://cotypist.app)
- Official: the company claims no copyright or ownership over text written with Cotypist. — [cotypist.app](https://cotypist.app)
- Press: Gruber says it respects macOS conventions, including where it stores local data and models. — [Daring Fireball](https://daringfireball.net/linked/2026/06/18/cotypist)
- An earlier search summary cited a Tom's Guide writer verifying local-only traffic with Little Snitch. I could not locate that article, so this is unverified.

### Inferences
- A clone should default telemetry to off. Cotypist's on-by-default analytics is a differentiation point for an open-source product, though Cotypist's analytics claim to exclude content.

### Gaps
- The full legal Privacy Policy (/privacy) was not fetched in detail. The help page doesn't cover license-check payloads, update-check payloads, or Paddle data handling.
- No independent network audit found.

## 4. Pricing and licensing (current as of Oct 2026, with history)

### Takeaway
Freemium subscription, closed source, sold via Paddle (merchant of record):
- **Free**: 100 Tab-accepted words per day, 1 Mac.
- **Plus**: $6/mo billed annually ($72/yr); about $8 billed monthly. Unlimited, 1 Mac.
- **Pro**: $9/mo billed annually ($108/yr); about $12 billed monthly. Unlimited, 3 Macs, big models, Labs.

Every install starts with a 30-day Pro trial with no card required. There is no lifetime license. During the beta (through about May 2026) the app was free, and the planned post-trial free tier was 50 words/day with a "Casual" tier name.

### Cited Findings
- Official pricing page — [Pricing](https://cotypist.app/pricing):
  - **Free**: "For occasional writing. 100 completed words a day." Typo indicator only (no full autocorrect), personalization up to "gentle," locked to default short completion length, 1 Mac.
  - **Plus**: 6/mo, "Billed annually as 72." Unlimited completions on 1 Mac, full autocorrect, balanced personalization, configurable completion length, global custom instructions.
  - **Pro**: 9/mo, "Billed annually as 108." Unlimited on up to 3 Macs, strong personalization, full model catalog, mid-line completion, clipboard awareness, per-app instructions, Labs (word alternatives, synonyms, Mac sync).
  - Annual billing is marked "Save 25%." Only words accepted with Tab count toward the Free limit ("suggestions you ignore are free"), and the counter resets daily.
  - After the trial, the account drops to Free automatically with settings kept. Cancelling keeps access until the end of the billing period.
  - EU/UK prices include VAT, and EU business reverse-charge is supported. A subscription is per person.
  - Many users will find Free sufficient, per the FAQ.
  - No education/team discounts or refund policy listed.
- Official press kit: Plus is $8/month or $72/year, and Pro is $12/month or $108/year. — [Press kit](https://cotypist.app/press)
- These figures reconcile: $6 and $9 are annual-billed monthly equivalents, and $8 and $12 are month-to-month (6/8 = 9/12 = 0.75, matching "Save 25%"). The pricing page's checkout screenshot shows "€144.00 incl. VAT" for Pro annual, which is unexplained and may be an outdated image or reflect a different VAT/currency. — [Pricing](https://cotypist.app/pricing)
- Press, consistent: "Plus is $6 a month or $72 a year … Pro $9/month or $108/year." — [MacSparky, 2026-06-19 (sponsored)](https://www.macsparky.com/?p=18981); [Daring Fireball](https://daringfireball.net/linked/2026/06/18/cotypist). AlternativeTo lists the subscription as "$6–$12 per month." — [AlternativeTo](https://alternativeto.net/software/cotypist/about/)
- One search summary claimed a later MacSparky post listed $10 and $15. When I checked the post itself, it said $6 and $9, so that claim is unverified/incorrect. — [MacSparky ?p=18981](https://www.macsparky.com/?p=18981)
- Sponsor promos offered 10% off the first bill for MacStories readers (until end of August 2026) and for MacSparky readers. — [MacStories sponsor](https://www.macstories.net/?p=198106); [MacSparky](https://www.macsparky.com/?p=18981)
- **History:**
  - Free during beta (2025 through spring 2026). — [Chinchilla Squeaks, 2025-04-25](https://chinchillasqueaks.substack.com/p/6-new-macos-and-ios-tools-for-april); [Sir Apfelot, 2025-12-14](https://www.sir-apfelot.de/cotypist-68457/); [Tao of Mac, 2026-04-11](https://taoofmac.com/space/apps/cotypist)
  - January 2026: a 30-day trial then a free tier limited to **50** completed words/day was described. A free "Casual" tier was planned with final pricing unpublished, expected to be similar to Timing's $30/yr. The Terms excluded a perpetual license. — [Implicator, 2026-01-01](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
  - May 7, 2026: still beta, with tentative Casual/Plus/Pro tiers. — [Blaze Today blog](https://blaze.today/blog/cotypist-alternatives-mac/)
  - The developer said a subscription is needed to cover the cost of supporting many apps. — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)
- Licensing: proprietary, freemium. — [AlternativeTo](https://alternativeto.net/software/cotypist/about/). One aggregator calls it open source; that claim is unsupported and contradicted by AlternativeTo.

### Inferences
- The 100-words/day free cap, counted only on accepted words, is a notable design choice. A free open-source clone removes this constraint entirely, and "100/day is tight" is a recurring user complaint.

### Gaps
- Monthly-billing prices aren't shown on the pricing page itself; they come only from the press kit.
- No refund policy found. The €144 checkout image is unexplained.

## 5. Supported and unsupported apps, quirks, permissions, macOS version

### Takeaway
Cotypist works wherever an app exposes its text through the macOS Accessibility API: native Cocoa apps, Chromium and Safari web fields, Word, and most Electron apps such as Notion, Obsidian, Teams, and WhatsApp. Slack is partial. Apps with custom text rendering or canvas editors fail or need workarounds: Google Docs (needs screen-reader mode), Google Slides, Zed, Sublime, Ghostty/Warp/Kitty, OneNote, Anki, and VMs/remote desktops. Firefox shows only a mirror window. The only required permission is Accessibility, which macOS 27 renames "Device Control and Data Access"; Screen Recording is optional. Requires macOS 14+ on Apple Silicon.

### Cited Findings
- Official compatibility table — [Compatibility](https://cotypist.app/compatibility):
  - **Browsers**: works in Safari, Chrome, Brave, Edge, Firefox, and Zen. Arc and Dia need setup.
  - **Email**: Apple Mail, Gmail (web), Outlook, and Mimestream work. Thunderbird is not supported.
  - **Writing**: Microsoft Word, TextEdit, Pages, Scrivener, and Google Sheets work. Google Docs needs setup. Google Slides is not supported.
  - **Notes**: Apple Notes, Notion, and Obsidian work. OneNote and Anki are not supported.
  - **Messaging**: Messages, Teams, and WhatsApp work. Slack is "Partial."
  - **Code editors**: BBEdit works. VS Code, Cursor, and Windsurf are partial (sidebar AI chats; main editor optional). Zed and Sublime Text are not supported.
  - **Terminals**: Terminal.app and iTerm work. Orca is partial (Claude Code and Codex only). Ghostty, cmux, Warp, and Kitty are not supported.
  - Final Cut Pro is not supported.
- Official: Cotypist needs apps to expose text fields to other software. Apps with custom text rendering may not work, and "the app developer would need to make changes on their side." It "can only see native Mac apps, not the contents of a virtual or remote window" (Parallels, Citrix). — [Compatibility](https://cotypist.app/compatibility)
- Official **Google Docs** setup: Tools > Accessibility, then check "Turn on screen reader support" and "Turn on braille support." Restart the browser or Mac if needed, and disable Smart Compose to avoid conflicts. Before v0.17.1, only Docs comment boxes worked; v0.17.1 notes "Completions now work in Google Docs comment boxes." — [Compatibility](https://cotypist.app/compatibility); [MacUpdater 0.17.1](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html). A 2026 review says it "only works in comments, not document body in Google Docs," which is likely outdated. — [search summary of macaiapps/toolradar listings](https://www.macaiapps.com/apps/cotypist/)
- Official **Arc/Dia** setup has two options. Option 1: open `chrome://accessibility`, check "Text Metrics," and keep that tab open (pinned). Option 2: launch with `--force-renderer-accessibility=complete`. Without either, suggestions appear in a mirror window. Text Metrics may reset after a browser restart or Space switch. — [Compatibility](https://cotypist.app/compatibility)
- Official: Firefox and Zen Browser show suggestions only in a mirror window. — [Troubleshooting](https://cotypist.app/help/troubleshooting)
- Official: Google Sheets is "idle in its small cells" so it doesn't interfere with tabbing. Google Slides is unsupported because its canvas doesn't expose the cursor position. Zed's UI isn't visible to other apps. Ghostty lacks support, and cmux inherits that because it's built on Ghostty. — [Compatibility](https://cotypist.app/compatibility)
- Official: Sublime Text, OneNote, and Anki "can't work" due to limited Accessibility API support. Full-screen mode may stop completions in some apps. Slack and Chrome completions "can occasionally stop appearing on their own," and restarting the app fixes it. — [Troubleshooting](https://cotypist.app/help/troubleshooting)
- Official **code editors**: the main editor is off by default, since editors have their own completion. Enable "Complete in Code Editors" in App Settings or use force-activate. — [Compatibility](https://cotypist.app/compatibility). Disabled by default in most IDEs and Terminal (Jan 2026). — [Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
- Official **terminals**: activates automatically when an AI agent prompt is detected (Claude Code, Codex, OpenCode, pi, Kilo CLI, and Cursor Agent per the Tips page). tmux, zellij, and Herdr are supported. Use force-activate for regular shell commands. — [Compatibility](https://cotypist.app/compatibility); [Help: Tips](https://cotypist.app/help/tips)
- User-reported working apps: desktop ChatGPT, Gemini, Claude, and Mistral apps, WhatsApp, Pages, Word, and web forms. — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)
- Official: password fields get no suggestions, intentionally, because macOS blocks access. Revealed passwords are caught only by the short-text length check (for recording). — [Troubleshooting](https://cotypist.app/help/troubleshooting); [Help: Personalization](https://cotypist.app/help/personalization)
- Official **conflicts**: Grammarly also uses Tab. Karabiner-Elements and TextExpander can intercept keys before Cotypist. **Secure Input** (e.g., from password managers) can disable the single-key full-completion shortcut in every app while Tab still works. Text typed twice means two Cotypist instances are running. — [Troubleshooting](https://cotypist.app/help/troubleshooting)
- Conflicts with macOS autocorrect and text suggestions: the developer recommends turning off macOS autocorrect — [PH launch page](https://www.producthunt.com/p/cotypist/cotypist-2) — and a reviewer recommends turning off macOS's own text suggestions to avoid double suggestions — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/).
- Historical fixes, v0.17.1 (2025-12-23): improved Word compatibility in multi-page documents, more eager activation in Messages, and a fix for completions "sticking around in the wrong place when scrolling." — [MacUpdater](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html)
- **Permissions** (official):
  - "Device Control and Data Access (called Accessibility on macOS 26 and earlier)" is required, and Cotypist "can't work without it."
  - Screen Recording is optional, to "read surrounding on-screen context."
  - Input Monitoring is not mentioned.
  - To reset a stuck permission, remove Cotypist from both lists, restart, and re-grant.
  — [Troubleshooting](https://cotypist.app/help/troubleshooting)
- Minimum OS: macOS 14 (Sonoma) or later on Apple Silicon. — [cotypist.app](https://cotypist.app); [Press kit](https://cotypist.app/press). MacUpdater metadata says 14.6. — [MacUpdater](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html)
- Platform: Mac only. A Windows/Linux interest waitlist exists, and the developer calls iOS keyboard extensions "very limited." — [Compatibility](https://cotypist.app/compatibility); [PH launch page](https://www.producthunt.com/p/cotypist/cotypist-2)

### Inferences
- "Electron" isn't an official category. Notion, Obsidian, Teams, WhatsApp, and VS Code sidebars work, which suggests Chromium/Electron AX trees are handled. Cotypist may force-enable the `AXManualAccessibility`/`AXEnhancedUserInterface` attributes, and the "Improve Compatibility With This App" toggle likely does this. That is inference; the Arc/Dia workaround of "Text Metrics" or `--force-renderer-accessibility=complete` shows it depends on Chromium exposing per-character bounds (`AXBoundsForRange`).
- The Secure Input caveat (the single-key full-accept shortcut breaks while Tab keeps working) suggests a CGEventTap for key interception, possibly with a fallback (Carbon RegisterEventHotKey) for Tab. The absence of an Input Monitoring requirement suggests the tap runs under the Accessibility grant. This is inference only.
- The Esc-pause, small-field idling, and agent-prompt detection are all heuristics a clone needs to make "always-on" completion tolerable.

### Gaps
- No official statement on Input Monitoring. The open-source clone Cotabby requires it ([search summary of SourcePulse/Cotabby](https://www.sourcepulse.org/projects/30330913)), but Cotypist's docs list only Accessibility and Screen Recording.
- Electron apps are not discussed as a category officially.

## 6. Maker, history, version timeline, community discussion, sentiment

### Takeaway
Cotypist is made by solo, non-VC-funded developer **Daniel Gräfe**, maker of the long-running Mac app Timing, through **Accelerated Thought GmbH** (Neuried/Munich, Germany; founded March 28, 2025). It had a long free beta (v0.7.2 by March 2025, v0.17.1 in December 2025), launched publicly on **May 27, 2026** around v0.22, and got a featured Product Hunt relaunch on June 23, 2026 (#3 of the day). Coverage is mostly positive and partly sponsored. The recurring criticisms are that suggestions distract, it's subscription-priced with a tight free tier, it uses RAM and battery, English works best, and some apps don't work.

### Cited Findings
- Company: Accelerated Thought GmbH, Munich, Germany. Founder Daniel Gräfe "also makes Timing" (a Mac productivity app around for about a decade). He's a solo developer, not venture-backed. Launch date: **May 27, 2026**. Founder quote: "Autocomplete shouldn't live in one editor." X handle @cotypist. — [Press kit](https://cotypist.app/press)
- Accelerated Thought GmbH was founded March 28, 2025 with €25,000 share capital in Neuried near Munich, and Gräfe is CEO. No funding raised. A Reddit post described an 18-month build. — [Implicator, 2026-01-01](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
- Origin: built after a habit of copying conversations into VS Code to get GitHub Copilot's inline completions. — [Product Hunt](https://www.producthunt.com/products/cotypist). The hunter describes "two years" of refinement. — [Product Hunt](https://www.producthunt.com/products/cotypist)
- **Timeline:**
  - 2025-03-03: **v0.7.2** is the latest, with performance and quality improvements. Separate keys for accept-word and accept-all, plus Esc to dismiss. — [MacSparky sponsor](https://www.macsparky.com/blog/2025/03/cotypist-ai-autocompletion-everywhere-on-your-mac/). Same day, a MacSparky members-only video review: "Testing Cotypist," by "Daniel Gräfe of Timing." — [MacSparky](https://www.macsparky.com/blog/2025/03/testing-cotypist/)
  - 2025-03-28: Accelerated Thought GmbH founded. — [Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
  - 2025-04-25: free beta, "a little noisy at times," "a few UI quirks." — [Chinchilla Squeaks](https://chinchillasqueaks.substack.com/p/6-new-macos-and-ios-tools-for-april)
  - 2025-12-14: free beta with a Gemma 3 default, a multi-model picker, and completion-length presets. — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)
  - 2025-12-23: **v0.17.1 (build 48)**. Word multi-page fix, Google Docs comment boxes, eager Messages activation, emoji tweaks, trailing-space option, Ministral 3B, multi-paragraph quality, compact-keyboard onboarding, scroll ghost-text fix. — [MacUpdater](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html)
  - 2026-01-01: beta, with planned pricing described. — [Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
  - 2026-04-11: "free during the beta period," with screenshot-derived context. — [Tao of Mac](https://taoofmac.com/space/apps/cotypist)
  - 2026-05-27: public launch (paid tiers). — [Press kit](https://cotypist.app/press)
  - 2026-05-28: **v0.22** noted as latest. Inline autocorrect, plus a Labs section with mid-line completions, British English, and RTL Arabic/Hebrew. — [MacSparky](https://www.macsparky.com/blog/2026/05/cotypist-brings-smart-autocomplete-to-every-mac-app/)
  - Around April–June 2026: switched the default to Gemma 4 E2B. The developer states this on Product Hunt — [Product Hunt](https://www.producthunt.com/products/cotypist) — but the exact version isn't documented.
  - 2026-06-18: Daring Fireball link post. — [Daring Fireball](https://daringfireball.net/linked/2026/06/18/cotypist)
  - 2026-06-23: Product Hunt featured relaunch. #3 Product of the Day, 315 upvotes and 618 followers on the PH page at time of fetch; mirror sites report 384 or 84 upvotes, which conflicts. — [Product Hunt](https://www.producthunt.com/products/cotypist); [hunted.space](https://hunted.space/dashboard/cotypist)
  - Third-party download catalogs list calendar-style versions ("2026.1.1," "2026.3.1, July 29, 2026"). These are unreliable piracy/aggregator sources, so the official current version number is unverified. — [macappdownload.com](https://macappdownload.com/cotypist/)
- No public changelog page: /changelog returns 404. — [cotypist.app/changelog](https://cotypist.app/changelog)
- MacUpdater claims availability on the Mac App Store. This conflicts with the official press kit ("notarized direct DMG with auto-updates") and is likely MacUpdater boilerplate. — [MacUpdater](https://www.macupdater.org/app_updates/appinfo/app.cotypist.Cotypist/index.html); [Press kit](https://cotypist.app/press)
- **Hacker News / Reddit**: I found no Hacker News thread, and no Reddit threads were indexed by the search tools. Implicator references a Reddit launch post ("18-month build") and Reddit users asking for one-time pricing. — [Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
- **Praise:**
  - Gruber: suggestions are "eerily good," the app is "very well-designed," and it respects privacy. — [Daring Fireball](https://daringfireball.net/linked/2026/06/18/cotypist)
  - David Sparks: "spooky-good," uses Pro daily. His posts are sponsored. — [MacSparky 2026-05-28](https://www.macsparky.com/blog/2026/05/cotypist-brings-smart-autocomplete-to-every-mac-app/); [MacSparky 2026-06-19](https://www.macsparky.com/?p=18981)
  - Quinn Nelson (Snazzy Labs): "It's so freakin' cool." — [Press kit](https://cotypist.app/press)
  - Product Hunt reviews: 5.0 from 5 reviews. Users call it "almost built into the operating system" and fast, and praise developer responsiveness. — [Product Hunt](https://www.producthunt.com/products/cotypist)
  - Accessibility: the developer reports users with ALS (including two Neuralink users) and a quadriplegic user relying on it. — [PH launch page](https://www.producthunt.com/p/cotypist/cotypist-2)
- **Complaints:**
  - Gruber "can't stand using it" because accurate suggestions distract him; he thinks it suits repetitive email writers and ESL writers. — [Daring Fireball](https://daringfireball.net/linked/2026/06/18/cotypist)
  - Sir Apfelot: distracting, accidental Esc clears suggestions, "Very Long" suggestions are slow (about 2 s on M1 Max), personalization is basic. Doubts subscription value at 100–200 words/day, would pay one-time but not €5/month, and hopes for Setapp. — [Sir Apfelot](https://www.sir-apfelot.de/cotypist-68457/)
  - Early builds over-suggested and caused backspacing; Tab-to-accept fixed it. Competing autocorrect needs tweaks. — [PH launch page](https://www.producthunt.com/p/cotypist/cotypist-2)
  - Requests for iOS and Windows versions. — [PH launch page](https://www.producthunt.com/p/cotypist/cotypist-2)
  - English best, other languages weaker. 100/day free is tight. Noticeable RAM and battery. No main-editor, Warp, Intel, Windows, or Linux support. Solo-dev bus-factor risk. — [Nicolas Deville, 2026-05-31](https://notes.nicolasdeville.com/apps/cotypist/)
  - Memory is noticeable on 8 GB machines, with occasional misfires in complex web apps. Risk of being "Sherlocked" by Apple. Users want one-time pricing. — [Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)

### Inferences
- Timing (the Mac time tracker) has historically been credited, in my background knowledge, to a developer named Daniel Alm. Both the official press kit and MacSparky identify Gräfe as Timing's maker, so this may be the same person under a changed name. This is unverified background knowledge; the report should simply say "maker of Timing."
- The unusually long beta (at least about 15 months, 0.7 → 0.22) and broad per-app special-casing suggest compatibility work is the dominant engineering cost. That matches the developer's justification for a subscription.

### Gaps
- No Hacker News discussion found. Reddit threads (r/macapps etc.) were not retrievable via search.
- Exact beta start date (likely 2024, given v0.7.2 by March 2025 and the "two years"/"18-month" remarks) is not confirmed.
- No user-count or revenue figures.
- Current version number as of October 2026 is not confirmed from an official source.
- No developer podcast or interview found.

## 7. Competitors

### Takeaway
Direct system-wide inline-autocomplete competitors on macOS:
- **Open source**: Cotabby (AGPL-3.0, llama.cpp or Apple Intelligence, OCR context), Joaov41/tabby (AGPL-3.0), and TabType (claims MIT, MLX).
- **Commercial**: Friendware, TabTabTab, InlineAI, BlinkWrite, and TypeSeer.

Adjacent competitors include Grammarly, Compose AI, GitHub Copilot, Apple's built-in predictive text and Apple Intelligence, and text expanders (Text Blaze, Rocket Typist, Typinator, Raycast, Alfred, Espanso).

### Cited Findings
- AlternativeTo alternatives to Cotypist — [AlternativeTo](https://alternativeto.net/software/cotypist/):
  - **Cotabby**: open source (AGPL-3.0), free, Mac. On-device system-wide autocomplete with ghost text at the cursor and screenshot OCR context.
  - **Friendware**: proprietary, paid. System-wide tab-to-complete.
  - **TabTabTab**: freemium. AI completions across Mac apps.
  - **InlineAI**: freemium.
  - **BlinkWrite**: paid. Screen-context writing assistant, 36 languages.
  - **TypeSeer**: paid. System-wide ghost-text autocomplete, UK.
  - **Jenni AI**: SaaS.
- Cotabby details: uses Apple Intelligence (macOS 26+) or local GGUF models via llama.cpp, plus screenshot OCR context. Built by University of Waterloo students, in beta, and requires Accessibility, Input Monitoring, and Screen Recording. Also listed: **tabby** (Joaov41, "Open-source, local-first AI autocomplete for macOS," AGPL v3, beta) and **TabType** (Product Hunt, "Free & MIT-licensed," local MLX model). These come from a search summary of the pages and the repo claims are unverified. — [SourcePulse Cotabby](https://www.sourcepulse.org/projects/30330913); [github.com/Joaov41/tabby](https://github.com/Joaov41/tabby); [Product Hunt TabType](https://www.producthunt.com/posts/1198164)
- Implicator lists Apple's built-in predictive text (a "Sherlock" risk), Grammarly (cloud, correction-focused, $12–15/mo), GitHub Copilot ($10/mo, code only), and cloud system-wide assistants. — [Implicator](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
- Text expanders positioned as alternatives by Blaze Today, the maker of Text Blaze (a biased source): Text Blaze, Rocket Typist, Compose AI (Chrome, cloud), Typinator, Raycast, Alfred, and Espanso (GPL-3.0). — [Blaze Today, 2026-05-07](https://blaze.today/blog/cotypist-alternatives-mac/)
- Gruber and Nicolas Deville point to GitHub Copilot as the conceptual model, and Deville recommends Copilot for code editors. — [Product Hunt](https://www.producthunt.com/products/cotypist); [Nicolas Deville](https://notes.nicolasdeville.com/apps/cotypist/)

### Inferences
- Cotabby is the closest existing open-source analogue and should be studied by the clone team, including its AGPL license implications. Cotypist's moats appear to be per-app compatibility polish, heuristics (idle rules, agent detection), model curation, and personalization, not the core model, since it uses off-the-shelf Gemma/Qwen weights.

### Gaps
- I did not verify Cotabby, tabby, or TabType repos directly (stars, activity, feature parity). Other researchers may cover them.
- No head-to-head quality comparisons found.
