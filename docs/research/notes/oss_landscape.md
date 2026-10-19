# Open-source and commercial landscape for a system-wide AI autocomplete (Cotypist alternative)

Method note: All GitHub star, fork, license, and "last push" figures below were pulled from the GitHub REST API (`api.github.com/repos/...`) and GitHub search API on **2026-10-18**. "Last push" (`pushed_at`) is used as a proxy for last commit date. crates.io figures were pulled from the crates.io API the same day. READMEs were read from raw.githubusercontent.com. No code was cloned or run. Reddit could not be reached (blocked to the research tooling), so user-sentiment evidence comes from GitHub issues, Hacker News, project READMEs, and review/listicle sites instead.

## Q1. Open-source projects that do system-wide AI autocomplete / ghost text in any app

### Takeaway
Since April 2026 there has been a wave of open-source Cotypist clones, almost all **macOS-only, Swift, Accessibility-API + local llama.cpp/MLX base models, Tab-to-accept ghost text**. Two are clearly ahead: **Cotabby** (1,084 stars, AGPL-3.0, very active, beta) and **KeyType** (572 stars, MIT, modular SwiftPM packages, last push late Aug 2026). Windows and Linux have only small hobby projects (mostly under 10 stars), and no single OSS project ships LLM ghost text on all three OSes.

### Cited Findings

**macOS: leading projects**

| Project | Stars / forks | Last push | Created | License | Stack | Inference | Capture / render | Maturity |
|---|---|---|---|---|---|---|---|---|
| [FuJacob/cotabby](https://github.com/FuJacob/cotabby) | 1,084 / 75 | 2026-10-15 | 2026-04-04 | AGPL-3.0 | Swift (SwiftUI/AppKit) | Apple FoundationModels (macOS 26+), in-process llama.cpp GGUF *base* models (Qwen3.5 0.8B/2B, Gemma 4 E2B/E4B), or a user-set OpenAI-compatible endpoint (Ollama/LAN/HTTPS) | AX focused field + caret; CGEvent tap for keys; inline ghost text or "mirror card" near caret; optional Screen Recording for OCR context and font matching | Labelled "beta"; 103 open issues; Homebrew cask; Sparkle updates |
| [johnbean393/KeyType](https://github.com/johnbean393/KeyType) | 572 / 32 | 2026-08-29 | 2026-05-31 | MIT | Swift, local SwiftPM packages | llama.cpp wrapper (`ModelRuntime`) | `MacContextCapture` (AX focus + caret + field snapshot), `CompletionUI` overlay, `TextInsertion` (pasteboard/keystroke) | Releases DMG; 21 open issues; describes itself as "a MIT-licensed alternative to the closed-source app Cotypist" |

- Cotabby: "Open-source, local-first AI autocomplete for macOS"; Tab accepts a word at a time, backtick accepts all; emoji autocomplete, `/` inline macros, one-key autocorrect (SymSpell); "No analytics, no telemetry, no crash reporting"; blocks generation in password/secure fields; maintained by students ("maintained by two students", later three named maintainers). — [Cotabby README](https://github.com/FuJacob/cotabby)
- Cotabby permissions: Accessibility (read text + caret, insert), Input Monitoring (observe typing, detect accept keys), optional Screen Recording (visual context and matching ghost-text font/size/position "where the app doesn't report them"). — [Cotabby README](https://github.com/FuJacob/cotabby)
- Cotabby pipeline: "CGEvent and focus poll -> FocusTracker -> FocusSnapshotResolver + AXTextGeometryResolver -> ... SuggestionEngineRouter -> Apple | in-process llama | OpenAI-compatible endpoint -> SuggestionTextNormalizer -> ... SuggestionOverlayPresenter -> OverlayController"; design rule: "Accessibility state is eventually consistent and app-specific. Every async result can be stale." — [Cotabby ARCHITECTURE.md](https://github.com/FuJacob/cotabby/blob/main/ARCHITECTURE.md)
- Cotabby's llama.cpp Swift wrapper is a separate repo, **CotabbyInference (MIT, 2 stars, last push 2026-09-27)**; Cotabby currently pins a fork branch adding a "required-prefix constraint" for mid-word anchoring. — [Cotabby ARCHITECTURE.md](https://github.com/FuJacob/cotabby/blob/main/ARCHITECTURE.md); [FuJacob/cotabbyinference](https://github.com/FuJacob/cotabbyinference)
- Cotabby AGPL note: "if you distribute a modified version or make one available to users over a network, you must provide the corresponding source code under the same license." — [Cotabby README](https://github.com/FuJacob/cotabby)
- KeyType repo layout: `AutocompleteCore`, `MacContextCapture`, `Prompting` (sectioned, budgeted prompt builder), `ModelRuntime` (llama.cpp wrapper), `ConstrainedGeneration` (logit masking, trie admissibility, search), `TokenProfiles`, `CompletionUI`, `TextInsertion`, `AppCompatibility` (per-app/per-domain override policy). — [KeyType README](https://github.com/johnbean393/KeyType)
- KeyType open issues include speed, rendering in Obsidian, and stray spaces in iMessage completions (each 10–12 comments, opened 2026-05-31). — [KeyType issues via GitHub search API](https://github.com/johnbean393/KeyType/issues)

**macOS: smaller / newer projects (all observed 2026-10-18)**

| Project | Stars | Last push | Created | License | Engine | Notable |
|---|---|---|---|---|---|---|
| [nilava/TabType](https://github.com/nilava/TabType) | 47 | 2026-10-09 | 2026-07-15 | MIT | GGUF base models (Qwen3 0.6B–4B, Gemma 4) | "early alpha"; on-device OCR of conversation above the field "like Cotypist"; 9-wide phrase beam search; token healing; per-app/per-website settings; AES-GCM-encrypted local writing history; iCloud E2E sync; README discloses heavy AI-assisted coding |
| [andlsac/Sombra](https://github.com/andlsac/Sombra) | 11 | 2026-06-08 | 2026-05-30 | MIT | llama.cpp + Metal | Personal project, "no commitment to support or stability"; inspired by Cotabby |
| [ThalesMMS/AutoComp](https://github.com/ThalesMMS/AutoComp) | 32 | 2026-08-18 | 2026-05-19 | Apache-2.0 | Remote OpenAI-compatible (default), Apple FoundationModels, optional in-process llama.cpp | "Current MVP"; inline or mirror-window modes; compatibility catalog; encrypted personalization |
| [nikiomori/Pretype](https://github.com/nikiomori/Pretype) | 16 | 2026-10-18 | 2026-06-27 | MIT | Local model, optional hosted (OpenAI, Anthropic, Gemini, Groq, Mistral, OpenRouter, DeepSeek, Ollama, LM Studio) | Claims 17–81 ms suggestions; ⌥Tab rewrite, ⌥⇧Tab reply drafts, dictation; community "app styles" |
| [dario-valles/shadowtype](https://github.com/dario-valles/shadowtype) | 12 | 2026-10-08 | 2026-06-09 | MIT | llama.cpp + Metal | Exposes local OpenAI-compatible API + MCP bridge; "Verify offline" button; a second repo `jacobbourne/shadowtype` also appears in search results |
| [chriscorbell/tabber](https://github.com/chriscorbell/tabber) | 0 | 2026-10-13 | 2026-10-13 | MIT | llama.cpp base models | v0.1; verified on macOS 27 in TextEdit, Safari, Chrome, Word, Notes, Messages, Mail, Discord, Slack web, Teams |
| [BrodySalvucci/Typist](https://github.com/BrodySalvucci/Typist) | 0 | 2026-10-12 | 2026-10-12 | MIT | llama.cpp | Written "from scratch" after studying Cotypist's behaviour |
| [mshll/ghostwriter](https://github.com/mshll/ghostwriter) | 2 | 2026-10-18 | 2026-10-14 | GPL-3.0 | Local model + Apple Intelligence actions | macOS 26+ only; snippets with `{ai: instruction}` placeholders; per-app rules |
| [mia-cx/stenotab](https://github.com/mia-cx/stenotab) | 1 | 2026-09-29 | 2026-07-23 | **none** | BYO model | "public alpha... currently has no license file"; 45 ms debounce, latest-request-only scheduling, token streaming into overlay |
| [semitechnological/tabyrus](https://github.com/semitechnological/tabyrus) | 4 | 2026-05-29 | 2026-04-13 | MPL-2.0 | MLX via **Rust backend** (dlopen FFI) | Swift frontend for AX/event taps/overlay; Rust holds all ML logic |
| [xiaohei210509/ztype](https://github.com/xiaohei210509/ztype) | 1 | 2026-10-17 | 2026-10-11 | MIT | Qwen3 1.7B, llama.cpp/Metal | Chinese word segmentation; thermal pauses, idle unloading |
| [r3dbars/tilde](https://github.com/r3dbars/tilde) | 3 | 2026-09-03 | 2026-04-24 | MIT | Local model | "a real macOS keyboard, not a floating window" (input-method approach); "open beta" |
| [F5ve-leaFCloveR/ghost-ime](https://github.com/F5ve-leaFCloveR/ghost-ime) | 0 | 2026-02-16 | — | MIT | Ollama (llama3.2:1b) with dictionary fallback | macOS input method (Input Sources), English only |
| [tahashafiei/Opentypist](https://github.com/tahashafiei/Opentypist) | 3 | 2026-05-18 | 2026-04-17 | MIT | Local | Minimal README |
| [griffinwork40/text-predictor](https://github.com/griffinwork40/text-predictor) | 1 | 2026-06-29 | 2026-06-08 | MIT | MLX (Qwen3) | — |
| [m-ghalib/S1S](https://github.com/m-ghalib/S1S) | 0 | 2026-09-29 | 2026-09-26 | MIT | MLX | Fork/derivative of TabType |

Sources for the rows: the linked repos' READMEs and the GitHub API. Extra detail:
- TabType's v2.1 notes say "we studied Cotypist's observable behaviour and the structure of its app", and that the font "was never read from the app... 0 of 984 placements had it". They added "Cotypist-style caret sanity checks", retries at 40/80/160 ms, a per-field line-height cache, a 9-wide beam search, and precomputing Tab chains. — [nilava/TabType README](https://github.com/nilava/TabType)
- The original `erenaydin0/TabType` repo, which search engines still index, now returns **404** from the GitHub API. Forks such as nilava, runakash and m-ghalib remain. — [GitHub API check, 2026-10-18](https://api.github.com/repos/erenaydin0/TabType); [search result listing](https://github.com/erenaydin0/TabType)
- Typist's motivation: Cotypist "used to be free; then it started capping how many words you could complete per day unless you paid". — [Typist README](https://github.com/BrodySalvucci/Typist)
- Typist and others call out apps that do not expose text through Accessibility (some terminals, and Google Docs unless its accessibility mode is on) as known limits. — [Typist README](https://github.com/BrodySalvucci/Typist)

**Historical macOS predecessors (pre-LLM)**
- [nathancahill/Anycomplete](https://github.com/nathancahill/Anycomplete): Hammerspoon/Lua, Google Autocomplete "Anywhere". 1,534 stars, last push 2023-05-07, no license detected.
- [pirate/macOS-global-autocomplete](https://github.com/pirate/macOS-global-autocomplete): C, MIT, 44 stars, **archived**, last push 2020-07-02.

**Windows**

| Project | Stars | Last push | License | Stack | Inference | Capture / render |
|---|---|---|---|---|---|---|
| [aixintan90/ghostype](https://github.com/aixintan90/ghostype) | 1 | 2026-07-26 | MIT | Python | **Cloud** (Anthropic Claude, default haiku tier) | pynput low-level keyboard hook; UI Automation TextPattern (ValuePattern fallback; `GetGUIThreadInfo` caret fallback); tkinter overlay; SendInput Unicode injection |
| [ariobarin/Fillit](https://github.com/ariobarin/Fillit) | 2 | 2026-07-21 | MIT | Python | **Cloud** (Groq, Llama 3 8B, about 300 ms) | Hotkey-triggered ghost-text overlay |
| [BraedynL0530/WinCotypist](https://github.com/BraedynL0530/WinCotypist) | 1 | 2026-09-21 | **none** | Go (hooks, buffer, insertion) + Python (FastAPI) + Electron UI | Local Ollama, SmolLM2 360M | Rolling keystroke buffer, not AX/UIA text read |
| [mdumr4/AI-Keyboard](https://github.com/mdumr4/AI-Keyboard) ("Frai") | 0 | 2026-10-11 | **none** | C++17 TSF IME DLL + Python daemon over IPC | Hybrid edge/cloud | Registers as a Windows IME through **Text Services Framework** and renders ghost text inline |
| [TabbyAIKeyboard/tabby](https://github.com/TabbyAIKeyboard/tabby) | 7 | 2026-09-09 | MIT | Electron 38 + Next.js; nut-js | **Cloud** (OpenAI/Groq/Cerebras/Gemini); needs Supabase in Docker and an OpenAI key | "Context-Aware Autocomplete" via a Ctrl+Space hotkey, plus an "Interview Copilot". Not passive ghost text |
| [PeterM45/SysInput](https://github.com/PeterM45/SysInput) | 4 | 2025-04-01 | MIT | Zig | None (learns from typing; dictionary) | Keystroke capture plus a suggestion popup near the cursor |
| [RMANOV/smartkey](https://github.com/RMANOV/smartkey) | 1 | 2026-10-17 | Core Apache-2.0, adapters GPL-3.0 (API: NOASSERTION) | Rust | **No LLM**: n-gram trie + Markov + CVM personal boost | IBus "Production", Windows TSF "experimental pre-release pilot", macOS IMK "In Development" |

Sources: the linked READMEs and the GitHub API.

**Linux**

| Project | Stars | Last push | License | Framework | Inference | Notes |
|---|---|---|---|---|---|---|
| [r3dbars/omatab](https://github.com/r3dbars/omatab) ("Oma Tab") | 2 | 2026-09-04 | MIT | **Fcitx5 input-method addon** (C++) | Local Ollama, default Qwen3.5-4B-Base Q8_0 with **FIM tokens** | Linux port of Tilde; inline preedit; 120 ms debounce; aborts stale requests; surrounding text 4 KiB before / 1 KiB after caret; optional OCR (Tesseract, grim); tuned for Omarchy (Arch + Hyprland); CLI `omatab ... --json` |
| [ekremx25/smartcomplete](https://github.com/ekremx25/smartcomplete) | 5 | 2026-10-14 | MIT | Fcitx5 addon (C++) | Mainly non-LLM (trie, bigrams, grammar rules) with "optional AI reranking" | Installer for Arch/Debian/Fedora; Wayland |
| [my7bropx/SmartType](https://github.com/my7bropx/SmartType) | 1 | 2026-06-23 | MIT | IBus engine (Rust) | Non-LLM word completer + autocorrect | Uses the IBus candidate window and preedit |
| [Ritanlisa/Fcitx5_LLM_plugin](https://github.com/Ritanlisa/Fcitx5_LLM_plugin) | 0 | 2026-03-16 | GPL-3.0 | Fcitx5 (C++) | llama.cpp GGUF/BitNet, CUDA | Next-token candidates in the **candidate panel** (digit to pick), not ghost text |
| [ThanabordeeN/ibus-llm-suggest](https://github.com/ThanabordeeN/ibus-llm-suggest) | 0 | 2026-06-30 | none | Python sidecar to ibus-typing-booster | OpenAI-compatible (OpenRouter/OpenAI/Ollama) | Hourly batch: the LLM generates phrases and injects them into typing-booster's DB. Not real-time |
| [simoabid/MindFlow](https://github.com/simoabid/MindFlow) | 1 | 2026-06-23 | MIT | IBus engine (Python) | Google (per description) | — |
| [r3dbars/omarchy-omatab](https://github.com/r3dbars/omarchy-omatab) | 5 | 2026-09-04 | MIT | QML bar widget for Oma Tab | — | — |

Also present: CJK/Japanese LLM IMEs, e.g. [BonoJovi/Bonolith](https://github.com/BonoJovi/Bonolith) (Rust, IBus + Fcitx5, MIT, 5 stars) and [volsifly/ibus_llm_pinyin_input](https://github.com/volsifly/ibus_llm_pinyin_input) (49 stars). These do conversion, not English continuation. Sources: GitHub search API, 2026-10-18.

### Inferences
- The macOS OSS space is crowded and converging on one architecture: AX focus/caret, a CGEvent tap, a borderless overlay with a mirror-card fallback, local GGUF **base** models through llama.cpp or MLX, Tab = one word, a second key = all, and per-app rules. Starting another macOS-only Swift clone has little differentiation value. A builder would do better to fork or reuse KeyType (MIT, modular) or contribute to Cotabby.
- Cotabby's AGPL-3.0 rules out copying its code into a permissively licensed or closed project. Its MIT `cotabbyinference` wrapper and its documented architecture can still be studied or reused. KeyType, TabType, Pretype, Shadowtype, Tabber and Typist are MIT and the most fork-friendly. stenotab, WinCotypist and Frai AI-Keyboard have **no license**, so their code cannot legally be reused.
- On Linux, the projects that work go through the **input-method framework** (Fcitx5/IBus preedit or candidates), not overlays. On Windows, both **UIA + overlay** and **TSF IME** have been prototyped, but none is mature.
- Maturity is low across the board. Apart from Cotabby and KeyType, every project has under 50 stars, is under 6 months old, and has one maintainer. Several disclose heavy AI-generated code.

### Gaps
- Many smaller repos have no tagged releases or notarized builds. I did not inspect release pages, so "maturity" is inferred from stars, age and README self-labels.
- Some search hits, such as `xiaohei210509/ztype`, `Depthkisculpt/cotypist` and `criticalinsight/OpenCotypist`, have almost no content or activity and were not examined in depth.
- I could not determine how many of the macOS projects actually support Intel Macs. Cotabby has an open issue about Intel iMac failures ([#755](https://github.com/FuJacob/cotabby/issues/755)).

## Q2. Adjacent OSS projects with reusable components

### Takeaway
The most reusable building blocks are: **espanso's Rust workspace** (cross-platform key detection, text injection, active-app info, clipboard; GPL-3.0), **KeyType's MIT SwiftPM packages** for the macOS side, **Fcitx5/IBus** as the Linux delivery mechanism (Oma Tab shows an LLM ghost-text Fcitx5 addon), and **WritingTools** (GPL-3.0, 2,470 stars) as a cross-platform reference for hotkey-driven selected-text rewriting with local or cloud LLMs. ibus-typing-booster is a long-lived, non-LLM Linux predictive input method that could host or feed an LLM layer.

### Cited Findings
- **espanso**: 14,653 stars, 482 forks, GPL-3.0, Rust, last push 2026-10-18, created 2019-08-30, 571 open issues. — [GitHub API: espanso/espanso](https://github.com/espanso/espanso)
- espanso's workspace contains separate crates: `espanso-detect` (key detection), `espanso-inject` (text injection), `espanso-ui`, `espanso-clipboard`, `espanso-info` (active app info), `espanso-ipc`, `espanso-mac-utils`, `espanso-config`, `espanso-match`, `espanso-render`, `espanso-engine`, `espanso-kvs`. — [espanso repo root listing via GitHub API](https://github.com/espanso/espanso)
- espanso license conflict: a vendor listicle calls espanso "MIT open source" ([Typilot](https://typilot.com/alternatives/cotypist)), but the GitHub API reports **GPL-3.0** ([espanso/espanso](https://github.com/espanso/espanso)). Trust the repo.
- espanso on Wayland: "Wayland support is currently experimental". It "requires access to the `/dev/input/eventX` and `/dev/uinput` interfaces" and uses a `CAP_DAC_OVERRIDE` capability via `setcap`. Non-US layouts must be set explicitly. App-specific configs "might work in KDE-Wayland distros if you can install `kdotool`". New keyboards need `espanso restart`. — [espanso Linux install docs](https://espanso.org/docs/install/linux/)
- **WritingTools** (theJayTea): "Apple Intelligence-inspired application for Windows, Linux, and macOS"; select text, press `ctrl+space`, pick Proofread/Rewrite/etc. or custom instructions; works with cloud or local LLMs. 2,470 stars, GPL-3.0, last push 2026-08-19. — [WritingTools README](https://github.com/theJayTea/WritingTools); GitHub API
- **ibus-typing-booster**: "completion input method to speed-up typing", started in 2010 for Fedora 15; context-sensitive completions, learns from input, hunspell, m17n input methods, emoji. 304 stars, last push 2026-10-17 (active), license not detected by the GitHub API. — [ibus-typing-booster README](https://github.com/mike-fabian/ibus-typing-booster)
- ibus-llm-suggest shows one way to add an LLM to typing-booster: periodically generate phrases and inject them into its DB. — [ibus-llm-suggest README](https://github.com/ThanabordeeN/ibus-llm-suggest)
- **Oma Tab** (Fcitx5) shows the full Linux recipe: the addon "owns key routing, inline preedit, and deterministic acceptance"; a worker thread debounces and calls Ollama, aborting in-flight requests; it uses cursor-aware surrounding text where apps expose it and falls back to recently typed text. Model downloads are pinned to sha256. — [omatab README](https://github.com/r3dbars/omatab)
- **SmartKey** shows a Rust shared-core pattern: `smartkey-core` (Apache-2.0) holds the key-event state machine and ghost-text lifecycle, and returns a platform-neutral Action list. Thin adapters (~200–400 LoC each) target IBus (PyO3), Windows TSF (COM) and macOS IMK (adapters GPL-3.0). — [SmartKey README](https://github.com/RMANOV/smartkey)
- **tabyrus** splits work between a Swift frontend (AX monitoring, event taps, overlay, menu bar) and a Rust backend loaded with dlopen (MLX inference, model download, hardware detection). — [tabyrus README](https://github.com/semitechnological/tabyrus)
- **ghostype** (Windows) documents a UIA-based capture chain: TextPattern for up to 600 chars before the caret, ValuePattern fallback, `GetGUIThreadInfo` caret fallback, Tab swallowed by the hook, and injection via SendInput Unicode events. — [ghostype README](https://github.com/aixintan90/ghostype)
- **Frai AI-Keyboard** (Windows) uses a split-process design: a lean C++ TSF DLL inside host processes and AI in a separate daemon over IPC, "to guarantee operating system stability". — [AI-Keyboard README](https://github.com/mdumr4/AI-Keyboard)
- Cotabby credits SymSpell (MIT) for multilingual autocorrect, GitHub gemoji for emoji, and Sparkle for updates. — [Cotabby README](https://github.com/FuJacob/cotabby)
- A DraftKey developer write-up lists macOS pitfalls: "There's no public API" for reading text across apps beyond Accessibility. Chromium/Electron apps may only build their AX tree when assistive tech is detected. Some apps ignore AX writes or skip undo. Pasteboard fallback clobbers the clipboard. Secure fields must be skipped. A commenter adds that Secure Input can block AX writes. — [dev.to: What I learned building a system-wide AI writing tool on macOS](https://dev.to/godnick/what-i-learned-building-a-system-wide-ai-writing-tool-on-macos-81m)

### Inferences
- A cross-platform design could reuse **espanso-detect / espanso-inject / espanso-info** for key detection, injection and active-app detection on all three OSes. The project would then have to be GPL-3.0 (or the crates would need re-implementing). espanso has no caret-geometry or field-text reading, so that layer would be new.
- For Linux, writing an **Fcitx5 addon (and/or IBus engine)** that renders the suggestion as preedit is the most robust way to get caret-anchored ghost text, especially on Wayland where global overlays and key hooks are restricted. Oma Tab (MIT) is the closest reference.
- For Windows, a **TSF text service** gives true inline rendering and reliable acceptance, at the cost of COM/DLL complexity. A UIA + overlay approach is easier but less reliable.
- The SmartKey-style "pure core + thin OS adapters" pattern maps directly onto a Rust core with Swift/C++/Rust shells.

### Gaps
- I did not verify whether espanso's crates are published on crates.io as standalone libraries or are only usable inside the workspace.
- I did not find an existing OSS Windows TSF text service with LLM ghost text that has a license and real usage.
- I did not verify the license of ibus-typing-booster (the GitHub API returns NOASSERTION).

## Q3. Commercial competitors and differentiators

### Takeaway
Paid any-app inline autocomplete is overwhelmingly **macOS-only and on-device**: Cotypist, Typeahead, MacAutocomplete, Friendware, TabTabTab, and FlowIn (which adds cloud reply drafting). Windows has **Lightkey** (on-device, non-LLM-branded prediction, lifetime license) and the OS's own **hardware-keyboard text suggestions**. **Typilot** is the only vendor found claiming macOS+Windows+Linux local ghost text, but that claim comes from its own site. Apple Writing Tools, Raycast AI, Grammarly and Compose are **rewrite/selection tools, not inline next-word autocomplete**. Apple's built-in "inline predictive text" is inline but OS-controlled.

### Cited Findings
- **Cotypist**: Mac only, Apple Silicon only, macOS 14+. "Your words and data never leave your device". Free tier = 100 completed words/day, then suggestions fade out. Plus = $6/mo billed annually ($72), unlimited on 1 Mac. Pro = $9/mo billed annually ($108), up to 3 Macs, largest models, per-app instructions, clipboard awareness, mid-line completion, and Labs (word alternatives, synonyms, sync between Macs). 30-day Pro trial. There is a waitlist for Windows/Linux. — [cotypist.app](https://cotypist.app); [cotypist.app/pricing](https://cotypist.app/pricing)
- AlternativeTo lists Cotypist as proprietary freemium at $6–12/month. Its listed alternatives are Cotabby, Friendware, TabTabTab, BlinkWrite, TypeSeer, Yoink AI and InlineAI. — [AlternativeTo: Cotypist](https://alternativeto.net/software/cotypist/about/)
- **Typeahead**: Mac only ("Mac-only for now"), macOS 14+, 8 GB RAM, on-device Gemma/Qwen or BYO GGUF, per-app styles, uses AX rather than Screen Recording, 16 languages. Current site pricing: $96/yr, $149 lifetime; monthly shown as $8 in the toggle but $10 in the FAQ. — [typeahead.ai](https://www.typeahead.ai/). Conflict: Product Hunt and reviewers list a **$79 one-time** price for Typeahead 2.0 ([Product Hunt](https://www.producthunt.com/posts/typeahead-2-0); [Typilot comparison](https://typilot.com/alternatives/cotypist)). It may have been a launch price.
- **MacAutocomplete**: $125 lifetime, local model, reads text around the cursor via Accessibility (from a search-result summary of the vendor page; not fetched directly). — [macautocomplete.com](https://macautocomplete.com/)
- **Friendware**: macOS "tab-to-complete everywhere" plus reply drafting; Show HN on 2026-03-12 drew 2 points and 2 comments. AlternativeTo shows ~$25–29/mo. Whether processing is local is claimed but inconsistent across sources. — [HN 47350605](https://news.ycombinator.com/item?id=47350605); [AlternativeTo: Friendware](https://alternativeto.net/software/friendware/about/)
- **TabTabTab**: Mac, freemium, $20/month per AlternativeTo. — [AlternativeTo: TabTabTab](https://www.alternativeto.net/software/tabtabtab/about/)
- **FlowIn**: inline autocomplete in "almost any Mac app" plus reply drafting/rewriting, which are cloud calls (vendor page). — [flowin.so](https://flowin.so/cotypist-alternative)
- **Typilot** (vendor-authored page): claims macOS, Windows 10/11 and Linux incl. Wayland, "system-wide ghost-text autocomplete via a local Ollama model", voice via local Whisper; $199 lifetime; 3-day trial; no open-source claim. — [typilot.com](https://typilot.com/alternatives/cotypist)
- **Lightkey** (Windows): "learns and predicts on your device and works offline"; "Your content is never sent to the cloud, in any application"; predicts up to 18 words ahead, Tab accepts a sentence; Pro/Business/AT lines plus Chrome/Edge extensions. — [lightkey.io](https://www.lightkey.io/). Deal sites list the lifetime Pro license at $169 regular and $49.99–$79.99 on promotion. — [Neowin](https://www.neowin.net/amp/save-52-off-on-a-lifetime-subscription-to-lightkey-pro/); [Windows Central](https://windowscentral.com/compose-emails-4-times-faster-lightkey-pro-text-prediction-now-52)
- **Windows 11 built-in "text suggestions" for hardware keyboards**: enabled under Time & language > Typing. "apps running in Windows 11 will give you suggestions as you type". Off by default. — [Thurrott Windows 11 Field Guide](https://www.thurrott.com/books/windows-11-field-guide/277060/keyboards-mice-and-touchpads)
- **Apple inline predictive text**: "in many macOS apps, you can... get inline predictions that complete the word or phrase you're typing" (System Settings > Keyboard > Text Input). Writing Tools is a separate proofreading/rewrite feature under Apple Intelligence. — [Apple Support: typing suggestions](https://support.apple.com/guide/mac-help/mchlp2299)
- **Raycast AI Commands**: "transform the selected text with simple instructions"; part of Raycast Pro ($8/mo billed annually at launch). Selection-based, not passive inline autocomplete. — [Raycast blog: Introducing Raycast Pro](https://raycast.com/blog/introducing-raycast-pro); [MacStories](https://www.macstories.net/news/raycast-introduces-a-pro-subscription-with-new-ai-sync-theming-and-clipboard-functionality/)
- **Grammarly desktop**: "works in 1 million+ apps and programs" with generative AI drafting/replies. No evidence found of inline next-word ghost-text autocomplete. — [grammarly.com/desktop](https://grammarly.com/desktop)
- **Compose**: listed by AlternativeTo as a freemium proprietary Mac tool that fixes grammar and tone via a keyboard shortcut in any app (rewrite, not autocomplete). — [AlternativeTo search result](https://alternativeto.net/software/cotypist/)
- **HyperWrite**: AI autocomplete only in the browser. — [HyperWrite: Cotypist alternatives](https://www.hyperwriteai.com/articles/cotypist-alternatives)
- Listicles (Blaze, HyperWrite) state that no open-source AI autocomplete exists for Windows/Linux and recommend espanso as the cross-platform OSS option. — [Blaze Today](https://blaze.today/blog/cotypist-alternatives-mac/); [HyperWrite](https://www.hyperwriteai.com/articles/cotypist-alternatives). GitHub shows small early projects that partly contradict this (see Q1 Windows/Linux tables).

### Inferences
- Cotypist's 100-word/day free cap and $72–$108/yr subscription, plus Mac-only Apple-Silicon-only support, are the clearest openings for a free OSS alternative. Paid rivals compete on one-time/lifetime pricing ($79–$199), not on platform breadth.
- Paid products differentiate on per-app styles/instructions, personalization from your own writing, screen/clipboard context, model catalogs, and polish of caret placement. Cotabby, TabType and Pretype already match most of these in OSS on macOS.
- Typilot's cross-platform claim is the only commercial signal that Windows+Linux local ghost text is being attempted. It should be treated as unverified marketing.

### Gaps
- I could not verify "Fluent" as an any-app autocomplete product. No reliable source was found.
- I could not fetch official prices for Lightkey (plans page not included), Friendware or TabTabTab, so the figures come from deal or aggregator sites.
- I did not verify whether Apple exposes an API for third-party apps to opt into inline predictions. A forum thread mentions a developer "inline prediction type" property, but I did not confirm its scope.
- I did not research Microsoft Word's own "Text Predictions" beyond its inclusion in Windows text-suggestion surfaces.

## Q4. Cross-platform frameworks and Rust crates for hosting such an app

### Takeaway
Tauri 2 (Rust) is mature and very active, and the Rust ecosystem covers most OS plumbing: **windows-rs** (official, UIA/TSF via COM), **uiautomation** (active), **atspi** (active, pure-Rust AT-SPI2 over zbus), **enigo** (input simulation, active), **global-hotkey** (active), and **llama-cpp-2** (active llama.cpp bindings). The weak spots are macOS Accessibility bindings (`accessibility`/`accessibility-sys` are thin and slow-moving, so most projects drop to objc2 or Swift) and **global keystroke listening**: `rdev`'s last release was in 2023 and `device_query` is archived. No OSS Cotypist alternative found is built on Tauri or Electron and ships passive ghost text. The only Electron/Tauri-style project (TabbyAIKeyboard) is cloud and hotkey-driven.

### Cited Findings (crates.io and GitHub data observed 2026-10-18)

| Crate / repo | Purpose | Latest version (date) | Downloads (all-time / recent) | Repo stars, last push, license |
|---|---|---|---|---|
| [tauri](https://crates.io/crates/tauri) / [tauri-apps/tauri](https://github.com/tauri-apps/tauri) | App shell | 2.12.4 (2026-10-14) | 37.3M / 14.8M | 111,978, 2026-10-15, Apache-2.0 (MIT dual per crate) |
| [windows](https://crates.io/crates/windows) / [microsoft/windows-rs](https://github.com/microsoft/windows-rs) | Win32/COM incl. UIA | 0.62.2 (2025-10-06) | 367M / 94M | 12,834, 2026-10-18, Apache-2.0 |
| [uiautomation](https://crates.io/crates/uiautomation) / [leexgone/uiautomation-rs](https://github.com/leexgone/uiautomation-rs) | Windows UI Automation wrapper | 0.25.1 (2026-09-04) | 852K / 474K | 201, 2026-09-04, Apache-2.0 |
| [atspi](https://crates.io/crates/atspi) / [odilia-app/atspi](https://github.com/odilia-app/atspi) | Linux AT-SPI2 (pure Rust, zbus) | 0.30.0 (2026-05-06) | 15.4M / 5.4M | 61, 2026-07-27, Apache-2.0 |
| [accessibility](https://crates.io/crates/accessibility) + [accessibility-sys](https://crates.io/crates/accessibility-sys) / [eiz/accessibility](https://github.com/eiz/accessibility) | macOS AXUIElement bindings | 0.2.0 (2025-03-22) | 123K / 64K (sys: 312K / 173K) | 91, 2026-01-01, Apache-2.0 |
| [macos-accessibility-client](https://crates.io/crates/macos-accessibility-client) | macOS AX permission helper | 0.0.2 (2026-01-18) | 570K / 158K | — |
| [objc2-app-kit](https://crates.io/crates/objc2-app-kit) | AppKit bindings (NSPanel overlays from Rust) | 0.3.2 (2025-10-04) | 72M / 31M | — |
| [rdev](https://crates.io/crates/rdev) / [Narsil/rdev](https://github.com/Narsil/rdev) | Global key listen + send | **0.5.3 (2023-06-26)** | 829K / 210K | 748, repo push 2026-05-12, MIT, 61 open issues |
| [enigo](https://crates.io/crates/enigo) / [enigo-rs/enigo](https://github.com/enigo-rs/enigo) | Simulate keyboard/mouse (text insertion) | 0.6.1 (2025-08-28) | 3.6M / 1.6M | 1,798, 2026-10-16, MIT |
| [device_query](https://crates.io/crates/device_query) / [ostrosco/device_query](https://github.com/ostrosco/device_query) | Poll key state | 4.0.1 (2025-07-21) | 539K / 114K | 199, **archived**, MIT |
| [global-hotkey](https://crates.io/crates/global-hotkey) / [tauri-apps/global-hotkey](https://github.com/tauri-apps/global-hotkey) | Global hotkeys only | 0.9.0 (2026-10-16) | 6.5M / 2.7M | 264, 2026-10-16, Apache-2.0 |
| [inputbot](https://crates.io/crates/inputbot) / [obv-mikhail/InputBot](https://github.com/obv-mikhail/InputBot) | Hooks + simulation (Windows & Linux only) | 0.6.0 (2023-08-17) | 84K / 4K | 461, 2025-08-01, MIT |
| [active-win-pos-rs](https://crates.io/crates/active-win-pos-rs) | Active window/app (per-app rules) | 0.11.0 (2026-05-26) | 222K / 58K | — |
| [x-win](https://crates.io/crates/x-win) | Active/open windows info | 5.8.0 (2026-08-11) | 37K / 6K | — |
| [get-selected-text](https://crates.io/crates/get-selected-text) | Cross-platform selected text (rewrite hotkey) | 0.1.6 (2024-05-29) | 22K / 4K | — |
| [evdev](https://crates.io/crates/evdev) | Linux raw input | 0.13.2 (2025-09-15) | 2.0M / 758K | — |
| [zbus](https://crates.io/crates/zbus) | D-Bus (IBus/Fcitx/AT-SPI) | 6.0.0 (2026-10-16) | 97M / 32M | — |
| [llama-cpp-2](https://crates.io/crates/llama-cpp-2) | llama.cpp bindings | 0.1.160 (2026-10-15) | 1.6M / 808K | — |
| [mistralrs](https://crates.io/crates/mistralrs) | Pure-Rust-ish LLM inference | 0.8.1 (2026-04-02) | 222K / 143K | — |
| [AccessKit/accesskit](https://github.com/AccessKit/accesskit) | Accessibility *provider* infrastructure for UI toolkits | — | — | 1,541, 2026-10-18, BSD-3-Clause |

Sources: crates.io API pages linked in the table; GitHub API for repos.

- Existing OSS stacks: almost all macOS clones are native Swift (Cotabby, KeyType, TabType, etc.). tabyrus is Swift plus Rust FFI. Linux projects are C++/Rust Fcitx5/IBus addons. Windows prototypes are Python, Go+Python+Electron, Zig, or C++ TSF. TabbyAIKeyboard is Electron 38 + Next.js + nut-js. — see Q1 sources.

### Inferences
- A pragmatic architecture is a **Rust core** (context assembly, prompt building, inference via llama-cpp-2 or an Ollama/OpenAI-compatible client, suggestion state machine, per-app policy) with **thin native shells**: a Swift/objc2 AX + NSPanel overlay on macOS, a C++/Rust TSF text service or UIA + layered-window overlay on Windows, and a Fcitx5/IBus addon on Linux. Tauri fits the settings/onboarding UI. Using its webview for the ghost-text overlay is probably a poor fit given the need for click-through, non-activating, AX-invisible, font-matched windows. This is inferred from the macOS projects' emphasis on font matching and AX-invisible overlays.
- AccessKit is for making your *own* UI accessible (provider side), so it does not help read other apps' text fields. This is based on its stated purpose as infrastructure for UI toolkits.
- Because `rdev` has had no release since 2023, a new project may need to fork it or write per-OS hooks: a CGEventTap on macOS, `SetWindowsHookEx` WH_KEYBOARD_LL on Windows, and the input method framework on Wayland. I did not verify rdev's Wayland support in this session. From prior knowledge, its listen API targets X11, not Wayland.

### Gaps
- I did not verify rdev's current Wayland status or the state of community forks (e.g., one used by RustDesk).
- I did not find a Rust crate that gives caret screen-rectangle geometry across OSes. Each project implements it per OS (AX `kAXBoundsForRangeParameterizedAttribute`, UIA TextPattern bounding rects, `GetGUIThreadInfo`, IME cursor rect).

## Q5. What users say they want from an open-source Cotypist

### Takeaway
User signals (Reddit was not reachable) consistently favour **no word caps or subscription, fully local and private models, low latency that does not slow typing, broad app compatibility (Google Docs, Obsidian, iMessage, Electron), per-app control, Intel/low-RAM support, and alternative backends (MLX, Ollama, LM Studio, OpenAI-compatible)**. Vendors and listicles repeatedly note the absence of Windows/Linux options. Cotypist itself runs a Windows/Linux waitlist.

### Cited Findings
- Typist author: Cotypist "used to be free; then it started capping how many words you could complete per day unless you paid... I've been bumping into that limit ever since"; wants "no word limits and no subscription". — [Typist README](https://github.com/BrodySalvucci/Typist)
- Cotypist free tier caps at 100 accepted words/day, and its pricing page collects emails for Windows/Linux interest. — [cotypist.app/pricing](https://cotypist.app/pricing)
- Cotabby issue demand (GitHub, observed 2026-10-18): "[Feature Request] Import co-typist context?" ([#282](https://github.com/FuJacob/cotabby/issues/282), open); "[Feature] Add MLX inference backend" ([#457](https://github.com/FuJacob/cotabby/issues/457)) and the follow-up PR "Add MLX as an autocomplete engine" ([#868](https://github.com/FuJacob/cotabby/issues/868)); "[Feature] Add Ollama model picker (UI parity with LM Studio)" ([#700](https://github.com/FuJacob/cotabby/issues/700)); "Switching model based on power status" ([#619](https://github.com/FuJacob/cotabby/issues/619)); "Google docs support" ([#264](https://github.com/FuJacob/cotabby/issues/264)) and "Typing in google docs doesnt work well" ([#660](https://github.com/FuJacob/cotabby/issues/660)); "Intel iMac" failure ([#755](https://github.com/FuJacob/cotabby/issues/755)); "Makes my writing slower" ([#773](https://github.com/FuJacob/cotabby/issues/773)); "Cotabby makes typing laggy in Obsidian" ([#276](https://github.com/FuJacob/cotabby/issues/276)); "Some letters on the keyboard do not register" ([#400](https://github.com/FuJacob/cotabby/issues/400)); app compatibility master tracker ([#626](https://github.com/FuJacob/cotabby/issues/626)); "Cut keystroke-to-ghost latency on the llama engine to under 60 ms" ([#875](https://github.com/FuJacob/cotabby/issues/875)).
- No Cotabby issue mentioning Windows or Linux as a platform request was found by GitHub issue search. The "windows"/"linux" hits were unrelated code PRs. — [GitHub search: repo:FuJacob/cotabby windows](https://github.com/FuJacob/cotabby/issues?q=windows)
- KeyType issues: "Issue: Speed" (12 comments), "Space in completions in imessage" (12), "Rendering issue in apps like Obsidian" (10), "Attempting to use a Gemini Model causes an error" (8), "Manually add apps to exclude", "Add a 'Force-Activate Completions' Keyboard Shortcut", "Does not work in signal". — [KeyType issues](https://github.com/johnbean393/KeyType/issues)
- Hacker News engagement is low: Cotypist submissions in Apr–Jun 2026 got 2–5 points and 0–1 comments; "Show HN: Friendware – Tab-to-complete everywhere on macOS" got 2 points. An older "Ask HN: any system wide text autocomplete apps?" dates from 2012. — [HN Algolia search: cotypist](https://hn.algolia.com/?q=cotypist); [HN 47350605](https://news.ycombinator.com/item?id=47350605); [HN 4127795](https://news.ycombinator.com/item?id=4127795)
- OSS READMEs market the same values users ask for: "No cloud. No account. No subscription. No telemetry." (TabType); "Verify offline" (Shadowtype); a release process that "proves it by watching every socket the app opens" (Tilde); Sombra recommends firewalls (LuLu, Little Snitch) to verify. — [TabType](https://github.com/nilava/TabType); [Shadowtype](https://github.com/dario-valles/shadowtype); [Tilde](https://github.com/r3dbars/tilde); [Sombra](https://github.com/andlsac/Sombra)
- Listicles state Cotypist "is Mac-only and resource-heavy" and that there is no OSS AI autocomplete for Windows/Linux. — [HyperWrite](https://www.hyperwriteai.com/articles/cotypist-alternatives); [Blaze Today](https://blaze.today/blog/cotypist-alternatives-mac/)

### Inferences
- Demand for an OSS alternative is driven mainly by **price/caps and privacy**. Once on macOS, the top complaints are **latency/lag and per-app breakage**, not missing features. The bar is reliability and speed in everyday apps.
- Explicit Linux/Windows demand shows up in vendor waitlists (Cotypist), vendor positioning (Typilot) and listicles, not in OSS issue trackers. That is expected, since the OSS projects are Mac-only and attract Mac users.

### Gaps
- **Reddit (r/macapps, r/LocalLLaMA, r/opensource) could not be accessed.** The research tooling's search and fetch are blocked for reddit.com. Direct Reddit sentiment on "open-source Cotypist", BYO-API and per-app rules is therefore missing.
- Product Hunt comments and the AlternativeTo user reviews for Cotypist contained no substantive user comments.

## Q6. Gaps no existing OSS project fills well

### Takeaway
The clear gaps are: **(1) one cross-platform OSS app (macOS + Windows + Linux) with LLM ghost text**; **(2) a mature, local-model Windows implementation** (existing ones are cloud-backed Python prototypes, unlicensed, or experimental TSF pilots); **(3) a distro-agnostic, polished Linux/Wayland implementation** (Oma Tab is Omarchy/Arch-tuned with 2 stars); **(4) a permissively licensed project with a sizeable community** (the largest, Cotabby, is AGPL); and **(5) robust coverage of hard surfaces** (Google Docs, canvas editors, terminals, Electron), plus Intel and low-RAM hardware.

### Cited Findings
- No cross-platform LLM ghost-text OSS project was found. The only multi-OS design, SmartKey, is non-LLM (n-gram/Markov), with Windows as an "experimental pre-release pilot" and macOS "In Development". — [SmartKey README](https://github.com/RMANOV/smartkey)
- Windows OSS: ghostype (Claude cloud, 1 star), Fillit (Groq cloud, 2 stars), WinCotypist (local Ollama, no license, 1 star), Frai AI-Keyboard (TSF, no license, 0 stars), TabbyAIKeyboard (Electron, cloud, needs Supabase/Docker). — [ghostype](https://github.com/aixintan90/ghostype); [Fillit](https://github.com/ariobarin/Fillit); [WinCotypist](https://github.com/BraedynL0530/WinCotypist); [AI-Keyboard](https://github.com/mdumr4/AI-Keyboard); [Tabby](https://github.com/TabbyAIKeyboard/tabby)
- Linux OSS: Oma Tab is "tuned for Omarchy" and installs via an Omarchy bar widget or bootstrap script (Fcitx5, Ollama, Tesseract, grim). SmartComplete is mainly rules/dictionary with optional AI reranking. The Fcitx5 LLM plugin uses the candidate panel and requires CUDA. — [omatab](https://github.com/r3dbars/omatab); [smartcomplete](https://github.com/ekremx25/smartcomplete); [Fcitx5_LLM_plugin](https://github.com/Ritanlisa/Fcitx5_LLM_plugin)
- espanso's Wayland support is "experimental", with app-specific configs limited (KDE with kdotool). This shows how hard per-app rules and key capture are on Wayland. — [espanso Linux docs](https://espanso.org/docs/install/linux/)
- Cotypist itself requires Apple Silicon. Cotabby has an Intel iMac failure report, and many OSS clones list "Apple Silicon" as a requirement (Shadowtype, Tabber, ztype, tabyrus). — [cotypist.app](https://cotypist.app); [Cotabby #755](https://github.com/FuJacob/cotabby/issues/755); [Shadowtype](https://github.com/dario-valles/shadowtype); [Tabber](https://github.com/chriscorbell/tabber); [ztype](https://github.com/xiaohei210509/ztype)
- Hard surfaces: Google Docs needs its accessibility mode (Cotypist, Typist). Code editors are limited to chat panels and terminals to AI-agent prompts (Cotypist, TabType, Pretype). AutoComp marks Sheets/Slides unsupported. — [cotypist.app](https://cotypist.app); [Typist](https://github.com/BrodySalvucci/Typist); [TabType](https://github.com/nilava/TabType); [Pretype](https://github.com/nikiomori/Pretype); [AutoComp](https://github.com/ThalesMMS/AutoComp)
- Licensing: Cotabby AGPL-3.0, ghostwriter GPL-3.0, tabyrus MPL-2.0, AutoComp Apache-2.0; KeyType, TabType, Pretype, Shadowtype, Tabber, Typist, Oma Tab, Tilde are MIT; stenotab, WinCotypist and AI-Keyboard have no license. — GitHub API, 2026-10-18 (see Q1 tables)
- Fine-tuned small models: Cotabby brands its catalog "tabby-2-nano/mini/base/pro", but these map to off-the-shelf Qwen3.5 / Gemma 4 base GGUFs from Hugging Face. No project was found publishing a purpose-trained autocomplete model. — [Cotabby README](https://github.com/FuJacob/cotabby). A llama.cpp fork named "Souffleuse" claims "parité Cotypist : moteur, modèle GGUF, FIM, perso SQLite/suffix-array, KV cache" (0 stars, no README content fetched). — [meffysto/cocotypist-llama](https://github.com/meffysto/cocotypist-llama)

### Inferences
- The highest-leverage contribution is a **cross-platform core plus native shells**, with Windows (TSF or UIA) and Linux (Fcitx5 + IBus, Wayland-first) as first-class targets. That is where both OSS and commercial supply is thinnest. The macOS shell could reuse MIT code from KeyType, TabType or Tabber.
- Secondary gaps worth targeting: a shared, open **per-app compatibility database** (TabType, Pretype's community "app styles", Cotabby's tracker #626 and AutoComp's catalog each maintain their own); **BYO-backend parity** (local GGUF/MLX, Ollama, LM Studio, OpenAI-compatible) behind one interface; and a **small purpose-tuned FIM/base model** for short continuations.
- Sustainability is a gap in itself. Most projects are under 6 months old with a single maintainer, and Cotabby describes itself as student-maintained and donation-supported.

### Gaps
- I did not measure real-world quality or latency of any project, since running code was out of scope.
- I could not confirm whether any project supports both X11 and Wayland with caret-anchored overlays outside the IME approach.
