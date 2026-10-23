# Architecture

Foretype has two halves joined by a small C ABI:

- **`core/`**: Rust crate `foretype-core`. Platform-independent: the policy gate,
  suggestion reuse, prompt building, inference (in-process llama.cpp or a server),
  personalization, the model catalog. It receives *snapshots* of the focused field and emits
  *suggestion state*. It never draws anything, so a Windows TSF service or a Linux
  Fcitx5/IBus preedit can render the same output.
- **`mac/`**: Swift package `Foretype`. Everything macOS-specific: Accessibility capture,
  the caret resolver, the ghost-text panel, event taps, text insertion, screen capture and
  OCR, hotkeys, menus, setup, the model downloader, Sparkle.

```
 macOS shell (Swift)                                     core (Rust, C ABI)
 ──────────────────                                      ─────────────────
 FocusTracker   AX thread: AXObserver + post-keystroke ─┐
                re-read burst + 0.5 s poll               │ Snapshot JSON (ft_engine_submit)
 ScreenContext  window capture + Vision OCR ─────────────┤ (+ screen_context text)
                                                         ▼
                                                 policy gate ─── compat/apps.json rules
                                                 recorder ────── encrypted history (opt-in)
                                                 session ─────── type-through, backspace, cache, accept
                                                 context ─────── byte-stable header + text before caret
                                                 worker thread ─ Runner: llama.cpp engine | HTTP server
                                                         │ Event JSON (callback)
 Controller ◄────────────────────────────────────────────┘ revision check, main thread
   GhostPanel   non-activating click-through panel at the caret (or mirror card)
   KeyTap       listen-only tap + consuming tap (enabled only while a suggestion shows)
   Inserter     Unicode CGEvents (≤20 UTF-16 units) or paste with clipboard restore
```

## Repository layout

| Path | Contents |
|---|---|
| `core/src/lib.rs` | `Core` (public API), `Snapshot`, `Settings`, `CoreConfig`, `Event`, submit pipeline, worker loop, recorder |
| `core/src/engine.rs` | In-process llama.cpp: KV-cache sync, token healing, greedy decoding, personal bias |
| `core/src/backend.rs` | `llama-server` and OpenAI-compatible HTTP backends |
| `core/src/context.rs` | Prompt builder |
| `core/src/words.rs` | Fragment splitting, word counting and limiting |
| `core/src/session.rs` | Suggestion reuse: type-through, backspace, accept, cache, dismiss |
| `core/src/policy.rs` | The gate, compatibility DB types, agent-prompt detection |
| `core/src/history.rs` | Encrypted writing history (ChaCha20-Poly1305) |
| `core/src/profile.rs` | Vocabulary profile and example selection |
| `core/src/details.rs` | The user's own details: fill cues and the prompt's writer line |
| `core/src/models.rs` | Model catalog (`models/catalog.json`) and tier choice |
| `core/src/ffi.rs`, `core/include/foretype_core.h` | C ABI |
| `core/src/bin/ft-replay.rs` | Headless replay and evaluation tool |
| `core/build.rs` | Links clang's runtime into test binaries and `ft-replay` |
| `compat/apps.json` | Per-app rules (CC0) |
| `models/catalog.json` | Downloadable models with pinned SHA-256 |
| `eval/corpus.jsonl` | 53-document evaluation corpus |
| `eval/details.json` | Users' details per corpus document, for `ft-replay --details` |
| `mac/Sources/Foretype/*.swift` | macOS shell (one file per component, see below) |
| `mac/Foretype.entitlements` | Signing entitlements (Contacts, for About You's "Fill from My Card") |
| `mac/Localization/*.lproj` | UI translations (`Localizable.strings`, `.stringsdict`, `InfoPlist.strings`); English is the base |
| `scripts/` | `build-mac.sh`, `package-mac.sh`, e2e tests, `ftdrive.swift` test driver |
| `packaging/homebrew/` | Cask template |
| `tools/spike/` | Phase 0 spike: AX probe, llama.cpp benchmarks, replay harness (archival) |

## Core

### Threads

- **Caller threads** (on macOS, the shell's AX thread and the main thread) call `submit`,
  `warm`, `accept`, `dismiss`, `configure`. `submit` runs the policy gate and the reuse
  paths synchronously and may emit an event before it returns.
- **`foretype.engine` worker thread** owns the `Runner` (the llama.cpp engine or an HTTP
  backend). It takes jobs from a single **latest-wins slot** (`pending: Mutex<Option<Job>>`
  plus a condvar): a new job replaces any queued one, and the running job is cancelled
  between decode steps when `latest` (an atomic revision) moves on.
- Events go out through the sink the shell registered (`FtEventCallback`), from whichever
  thread produced them.

### Submit pipeline (`Core::submit`)

In order; the first rule that applies decides:

1. Store `revision` as `latest` (this cancels in-flight work for older revisions).
2. Paused (`settings.paused`) → hide (`policy`, `paused`); nothing is queued.
   `settings.enabled` false → hide (`policy`, `disabled`). (The macOS shell no longer sends
   `enabled`: its pause covers it.)
3. `settings.only_apps` non-empty and the app is not in it → hide (`notInOnlyApps`).
4. `policy::evaluate` → hide with a reason. Checks, in order: secure input, secure field
   (`AXSecureTextField`, or "password"/"secure" in the role description), role not
   `AXTextArea`/`AXTextField`/`AXComboBox`, `AXSearchField` (unless forced), a selection,
   IME composition (`marked_len > 0`), app disabled by the user, app disabled by default in
   the compat DB (unless the user enabled it, forced, or the field's label matches the
   rule's `allow_fields`, e.g. a code editor's chat input), agent-prompt-only app whose
   caret line is not an agent prompt, single-line field narrower than 260 pt, more than 8
   non-space characters after the caret on the line (lifted when `mid_line` is on and the
   built-in engine is loaded), fewer than 2 characters typed, a partial word longer than 30
   characters.
5. Agent-prompt apps (terminals): `text_before` is replaced by the prompt's own text.
6. Recorder (`observe`) when personalization is on.
7. Dismissed for exactly this text (unless forced) → hide (`dismissed`).
8. **Type-through**: the text extends the shown suggestion's base by a prefix of the
   suggestion, or backspaces up to 24 characters into it → emit the rest (`typeThrough`),
   no inference.
9. **Typing aids** (no model): one of the user's details the text asks for, at the end of
   a line → its exact value (`details`; see *Your details* below); an `:name` emoji shortcode at a word start → the best
   gemoji match as a replacement (`emoji`; no match → hide, `shortcode`); a misspelled word
   just finished (`spell_word`/`spell_correction` from the shell) → its correction as a
   replacement (`autocorrect`), unless it is capitalized mid-sentence, an acronym, has
   digits, or is one of the user's own words; a partial word the shell's spell checker says
   can't become a word (`spell_fragment: "typo"`) → hide (`typo`), unless capitalized, with
   digits, shorter than 3 letters or a prefix of the user's own words.
10. **Cache**: an exact `(field_key, text_before)` hit, from earlier suggestions or a
   prefetch → emit (`cache`). Skipped mid-line (the key doesn't hold the text after the
   caret).
11. Build the prompt (personal examples are chosen once per field and cached) and enqueue a
    `Complete` job; emit an empty `pending` event so the shell hides the stale ghost.

`warm` enqueues a zero-token prefill of a field's prompt only if nothing is queued, and
never while paused.

### Worker loop

- **Load**: the local engine (model file) or an `HttpBackend`; emits `status` events
  `loading` / `ready` / `error`.
- **Idle unload**: with no job for `unload_after_s` (default 300 s; the macOS shell sends 60
  while saving energy) the local engine is dropped (about 1 GB freed; `status: idle`) and
  reloaded on the next job.
- **Pause**: `configure` with `paused: true` empties the job slot, bumps `latest` (a running
  completion stops at its next decode step; warm-ups and prefetches check the flag too) and
  wakes the worker, which drops the engine at once (model freed, or the server client),
  emits `status: paused` (`detail: "model unloaded"` for the local engine) and sleeps on the
  condvar with no timeout work. `paused: false` wakes it again: a server backend is rebuilt
  at once (`ready`), the local engine reports `idle` and loads on the first job. A core
  created with `paused: true` (the app launched while paused) loads nothing until then.
- **Vocabulary**: when the profile generation counter changed, the engine re-derives its
  personal bias.
- **Debounce**: if `debounce_ms > 0` (the shell sets 80 ms on battery) and the job is
  mid-word, wait that long; a newer keystroke cancels the job.
- **Complete** → session `set` → emit `suggestion` (`source: model`, `ms`, `prefilled`,
  `stop`).
- **Prefetch** (when `settings.prefetch`; the shell enables it on mains power only):
  complete the prompt for `text_before + suggestion` and `remember` it in the session cache.
  It is cancelled as soon as any job is queued.

### Engine (`engine.rs`)

- **One context, one sequence.** `sync(tokens)` keeps the longest common prefix with the
  tokens already in the KV cache, removes the rest (`clear_kv_cache_seq`), and prefills
  only the tail; the last prompt token is always re-decoded so its logits are fresh.
- **Rollback**: after generating, the generated tokens are removed again, so the cache
  always mirrors the prompt and the next keystroke prefills only 0–2 tokens.
- **Token healing**: the prompt stops before the partial word; while the generated bytes
  are shorter than the typed fragment, only tokens whose bytes agree with the fragment are
  allowed (logit masking over the detokenized vocabulary). Mid-word completion therefore
  works even when the fragment is not a token boundary, and the prompt prefix stays
  identical for a whole word.
- **Mid-line**: a prompt with a `suffix` (the rest of the caret's line) is still a plain
  continuation; the suggestion is capped at 3 words and cut where it starts repeating the
  rest of the line. Qwen3's fill-in-the-middle tokens were tried and produced noise on
  prose (`docs/MEASUREMENTS.md`).
- **Phrase beam search** (`beam_width` > 1, truncating models): beams live in sequences
  1..16 of a unified KV cache (copying a sequence only tags cells; sequence 0 keeps the
  prompt, so nothing is rolled back), one batched decode per step, the `beam_width` best
  children by summed log-probability survive, the same healing, bias and stops as greedy
  (`stop_before`), and the finished phrase with the best mean log-probability wins (its
  first word may differ from greedy's). Recurrent models stay greedy.
- **Greedy decoding** with stops: newline; the next word would exceed `max_words`; a
  sentence end before a new word (`stop_at_sentence_end`); end-of-generation token; a
  deadline (`deadline_ms`, default 300 ms, counted from the end of prefill); token budget
  `max_words * 3 + 8 + fragment length`. A word cut off by the budget or the deadline is
  dropped.
- **Personal bias** (`set_vocabulary`, `personal_strength` logits at full weight):
  at a word start, boosts the single token of `" word"` for the user's whole-word tokens;
  while a word is in progress (typed or generated), boosts the next token of the user's
  words that extend it (up to 8 candidates). Boosts are non-negative and sparse, so the
  argmax is either the unboosted winner or one of the boosted tokens.
- **Rollback by architecture** (`Rollback`, chosen at load):
  - *Truncate*: dense full-attention models (Qwen3) and sliding-window models (Gemma 4).
    The context is created with a full-size SWA cache (`swa_full`), so cells that left the
    512-token window are kept and removing cells past a position is always valid; at a
    2,048-token context this costs little memory.
  - *Snapshot*: recurrent and hybrid models (Qwen3.5's Gated DeltaNet layers). Their
    running state can't be cut back, so `sync` decodes the prompt up to its last token,
    saves the recurrent state (`state_seq_get` with `PARTIAL_ONLY`, about 20 MB for Qwen3.5
    0.8B), then decodes
    the last token. Rolling back restores the newest snapshot whose tokens are a prefix of
    the target and removes the attention cells after it; generation is undone by returning
    to the prompt's own snapshot. Up to 4 snapshots are kept (most recent first); with none
    usable the cache is cleared and the prompt prefilled from scratch.
  - `ft-replay --check-cache` types documents (with backspaces) through a reusing engine
    and through one reset before every request and counts differing suggestions.
- The backend, model and context live behind raw pointers and are freed in order in `Drop`
  (context, model, backend); Metal asserts at process exit if a context outlives its
  device.

### Prompt format (`context.rs`)

```
[Text visible on screen]                         ← screen_context, last ≤1,500 chars, lines
...                                                 starting with "[" dropped
[End of screen text]

[Earlier writing by the same person in Mail]     ← personalization examples (≤2 × 280 chars)
...
---
...
[End of earlier writing]

[Written by Priya Raman (Product Manager, Acme)]      ← the user's details (About You), local models only
[Written in Mail — Re: planning (mail.example.com)]   ← app, window title (≤80), URL host
[Writer's notes: …]                                   ← global + per-app instructions (≤400)

Hi Priya,\n\nThanks for the                     ← body: text before the caret, up to the
                                                    partial word ("prefix")
fragment = " no"                                 ← typed partial word + its leading space
```

- The body window is at most `max_body_chars` (1,600) bytes. Its start moves in 512-byte
  steps and lands after whitespace, and the shell sends a text window aligned to 1,024
  UTF-16 units, so the prefix stays byte-stable for many keystrokes.
- `words::split_fragment` defines the fragment: the trailing run of word characters
  (letters, digits, `'`, `’`, `-`, `_`) plus the single space before it. After a space the
  fragment is `" "`; after punctuation or a newline it is empty. Base-model BPE attaches
  spaces to the following word, so a prompt never ends in a bare space.
- Everything that changes rarely (screen text, examples, header) comes first; everything
  that changes per keystroke comes last.
- The writer's notes are the user's custom instructions. They start as the defaults in
  `core/data/default-instructions.json` (`instructions.rs`, `ft_default_instructions`): one
  note for every app and, by bundle ID, optional notes per kind of app (none ship). The
  shell stores only what the user changed, so untouched notes follow the defaults of the
  installed version; an empty note the user saved stays empty.
- The `shell` backend's Apple model is instruction-tuned, so `AppleModel.swift` gives it
  fixed instructions of its own (continue the text where it stops, at most `max_words`
  words, nothing else) and sends this prompt after "Continue this text:".

### Your details (`details.rs`)

The shell sends the user's details with `ft_engine_set_details` (fields switched off arrive
empty; all empty means off). `fill(text_before, details)` looks only at the caret's line:

- **Sign-off**: the line before is a sign-off on its own (`Regards`, `Best regards`,
  `Thanks`, `Cheers`, `Sincerely`, `--`, … with an optional `,` or `!`) → the name, with the
  current line as its typed start.
- **Cue phrases** (about 150, matched case-insensitively, `’` as `'`): `Word` cues anywhere
  after a word boundary (`my email is`, `call me on`, `i work at`, `reach me at` → email or
  phone, whichever matches); `LineStart` labels after optional indentation or a bullet
  (`Email:`, `Phone:`, `Address:`); `AfterGreeting` (`Hi Sam, this is` → name). The cue must
  end a word and be followed only by spaces and the typed start of the value; the cue
  nearest the caret wins. Ambiguous phrases (`I'm `, `it's`, `Title:`, `Role:`) are left
  out.
- **Match**: the typed start must be a prefix of the value: same case → the rest as a
  continuation (with a leading space when the cue has none yet); other case → the whole
  value replacing the typed start. A value already typed in full, unset, multi-line or
  over 300 characters → nothing, and the pipeline goes on (emoji, autocorrect, model).
- Skipped mid-line. Runs before the typo gate (an email address is no typo).
- Session: a fill is not cached and not typed through (it is recomputed per keystroke). A
  name is accepted word by word; every other detail is `whole`: one Tab inserts all of it.
- **Writer line**: with `in_prompt` and a local backend (built-in or the shell's Apple
  model, never `llama-server`/`openai`), `[Written by Name (Job title, Company)]` goes into
  the header before `[Written in …]`. `UserDetails`'s `Debug` prints only which fields are
  set, and `redact` masks pieces of the values in the core's debug lines (model text).

### Emoji (`emoji.rs`, `core/data/emoji.tsv`)

1,913 gemoji shortcodes (MIT, Unicode ≤ 15.0). `typed_shortcode` accepts a colon at a word
start (after whitespace, an opening bracket or nothing) followed by 2+ of `a-z0-9_+-`, so
times (`10:30`) and URLs don't trigger. `lookup` ranks an exact name, then a list of
common names, then the shortest, then Unicode order.

### Session (`session.rs`)

Holds the shown suggestion (`base`, `suggestion`) for one field, a 64-entry cache and a
dismissal marker.

- `type_through`: typed characters matching the suggestion advance it; backspacing up to
  24 characters (no newline) re-prepends the deleted text.
- `accept(NextWord | All)`: returns `(insert, remaining)` and advances `base`, so a second
  Tab before the host reports the edit still inserts the following word.
- `dismiss`: suppresses suggestions until the text changes.
- **Replacements** (`set_replacement`): an emoji or a correction stands for text just
  before the caret (`replace`). Accepting either key returns `Accepted { insert, remaining:
  "", replace }` and the shell deletes `replace` (Backspace per character) before
  inserting; replacements are never typed through or cached.
- `remember`: cache-only insert used by the prefetch.
- **Fills** (`set_fill`): one of the user's details, a continuation or (case differs) a
  replacement; `whole` makes either key accept all of it. Not cached, not typed through.

### Compatibility database (`compat/apps.json`, `policy.rs`)

```json
{
  "apps": { "<bundle id>": { "disabled": bool, "agent_prompt_only": bool,
                             "insertion": "keystrokes|paste|paste-long|first-word-then-paste",
                             "prime": "chromium|electron", "caret": "pixel|ax",
                             "note": "…" } },
  "prefixes": { "com.jetbrains.": { "disabled": true } },
  "agent_prompt": { "borders": ["│", "┃", "|"], "markers": ["> ", "› ", "▌ "] }
}
```

`caret` is read only by the shell: `pixel` always takes the caret from screen pixels (the
app's AX geometry is wrong), `ax` never does; unset means AX with the pixel locator as the
fallback when AX gives nothing.

The longest matching prefix applies when there is no exact entry. An agent prompt line is
`[whitespace][border][whitespace]marker text`; shell prompts (`$`, `%`, `❯`) don't match.
The file is compiled into the core (`include_str!`).

### Personalization (`history.rs`, `profile.rs`, recorder in `lib.rs`)

- **Recorder**: tracks the focused field (`start` text at focus, `last` text, `accepted`
  flag set by `accept`). A field is finished when focus moves to another field or its
  text shrinks to under half (a sent chat message). If a suggestion was accepted there,
  the text typed since focus (after the common prefix with `start`) is recorded when it is
  at least 20 characters. Fields the gate rejects are never tracked.
- **History file**: frames of `u32 LE length | 12-byte nonce | ChaCha20-Poly1305
  ciphertext of the JSON record {ts, app, text}`. Frames that fail to decrypt are skipped.
  At most 3,000 records (compacted atomically). The 256-bit key is supplied by the shell
  (hex) and never stored by the core. Without a key, history is memory-only.
- **Profile**: words of 4+ characters with no digits, minus a list of very common English
  words; counted case-insensitively, most recent spelling kept. The bias uses words seen at
  least twice (top 3,000), weighted `ln(1+count)/ln(1+max)`.
- **Examples**: up to 2 records from the same app, at least 30 characters, ranked by shared
  words with the current text, then recency, truncated to 280 characters at a word
  boundary; chosen on the field's first prompt.
- **Strength**: gentle 1.0, balanced 2.0, strong 4.0 logits at full weight.

### HTTP and shell backends (`backend.rs`)

| | `llama-server` | OpenAI-compatible | `shell` (Apple on-device model) |
|---|---|---|---|
| Endpoint | `POST /completion`, streamed | `POST /v1/completions`, streamed | `ft_engine_set_completer` callback, `{"prefix","max_words"}` in, text out |
| Prompt | prefix | prefix (without the partial word) | as OpenAI |
| Healing | GBNF grammar `root ::= "<fragment>" [^\n]*` | reply used only if it starts with the fragment; otherwise a second request with prefix + fragment | as OpenAI (replies are whole, so the last word is kept) |
| Caching | `cache_prompt: true`, zero-token warm | last `(prefix, reply)` reused for every keystroke in a word | as OpenAI |
| Bias | `logit_bias` for the user's single-token words (found once per profile with `/tokenize`, up to 400) | none | none |

Responses are read line by line, so a new keystroke abandons a request between chunks. The
shell completer blocks the engine thread; on macOS `AppleModel.complete` runs Foundation
Models with a fresh session per request (greedy, 3 s timeout) and adds the leading space
the instruction-tuned model leaves out. FoundationModels is weak-linked (macOS 26+).

### Model catalog (`models.rs`)

`ft_model_catalog(ram_gb)` returns the models whose `min_ram_gb` fits, with `recommended`
set: tier `light` (Qwen3 0.6B Q8_0) below 12 GB, `default` (Qwen3 1.7B Q4_K_M) otherwise.
The `quality` tier (Qwen3 4B Q4_K_M, 16 GB+) is never picked automatically.

### C ABI

All strings are UTF-8 JSON. Strings returned by the core must be freed with
`ft_string_free`.

| Function | Purpose |
|---|---|
| `ft_engine_new(config_json, callback, ctx)` | Create; the model loads on the worker thread |
| `ft_engine_free(engine)` | Stop the worker, free the model |
| `ft_engine_submit(engine, snapshot_json)` | Field changed |
| `ft_engine_warm(engine, snapshot_json)` | Prefill a newly focused field |
| `ft_engine_accept(engine, mode)` | 0 next word, 1 all → `{"insert","remaining","replace"}` or NULL (delete `replace` before the caret first) |
| `ft_engine_dismiss(engine, field_key, text_before)` | Esc |
| `ft_engine_configure(engine, settings_json)` | Replace settings |
| `ft_engine_set_details(engine, details_json)` | The user's own details (below); returns false if the JSON doesn't parse |
| `ft_engine_set_completer(engine, callback, ctx)` | Completer for the `shell` backend (request JSON in, malloc'd text out) |
| `ft_engine_compat_rule(engine, bundle_id)` | Rule JSON for an app |
| `ft_engine_history_stats` / `ft_engine_clear_history` / `ft_engine_import_history` / `ft_engine_open_history` | Personalization |
| `ft_model_catalog(ram_gb)` | Model list (no engine needed) |
| `ft_default_instructions()` | The custom instructions a fresh install starts with, `{"global", "apps": {bundle: note}}` (`core/data/default-instructions.json`; no engine needed) |

**CoreConfig** (`ft_engine_new`): `model_path`, `n_ctx` (2048), `n_gpu_layers` (999),
`n_threads` (4), `settings`, `history_path`, `history_key_hex`, `backend`
(`local`|`llama-server`|`openai`|`shell`), `backend_url`, `backend_model`, `backend_api_key`.

**Settings** (`ft_engine_configure`): `enabled`, `paused` (false), `length_words` (4), `stop_at_sentence_end`,
`instructions`, `app_instructions` {bundle: text}, `disabled_apps`, `enabled_apps`,
`only_apps`, `deadline_ms` (300), `max_body_chars` (1600), `unload_after_s` (300),
`debounce_ms` (0), `prefetch` (true), `personalize` (false), `personalize_strength` (1),
`personal_examples` (true), `emoji` (true), `autocorrect` (true), `typo_gate` (true),
`mid_line` (false), `beam_width` (1).

**UserDetails** (`ft_engine_set_details`): `name`, `email`, `phone`, `company`, `job_title`,
`address`, `website` (strings, empty = unset or switched off), `in_prompt` (false).

**Snapshot** (`submit`/`warm`): `revision`, `field_key`, `bundle_id`, `app_name`,
`window_title`, `url`, `role`, `subrole`, `role_description`, `description` (label or
placeholder), `text_before`, `text_after` (rest of the caret line), `screen_context`,
`selection_len`, `marked_len`, `secure_input`, `field_width`, `field_height`, `force`,
`spell_fragment` (`word`|`prefix`|`typo`|empty), `spell_word`, `spell_correction`.

**Events** (callback):

```json
{"type":"suggestion","revision":42,"text":" going next week","source":"model","ms":71.2,"prefilled":1,"stop":"words"}
{"type":"suggestion","revision":43,"text":"","source":"policy","reason":"secureField"}
{"type":"suggestion","revision":44,"text":"🎉","source":"emoji","replace":":ta","label":":tada:"}
{"type":"suggestion","revision":45,"text":"ya.raman@example.com","source":"details","label":"email"}
{"type":"status","state":"ready","detail":"loaded in 846 ms"}
{"type":"status","state":"paused","detail":"model unloaded"}
```

`status` states: `loading`, `ready`, `idle` (model unloaded after `unload_after_s`, or just
resumed), `paused`, `error`.

`source`: `model`, `typeThrough`, `cache`, `pending`, `policy`, `dismissed`, `error`,
`emoji`, `autocorrect`, `details`. An empty `text` means hide. `replace` (with `label`) marks a
replacement: the shell shows `🎉 :tada:` or `→ receive` and deletes `replace` on accept. For
`details`, `label` names the detail (`name`, `email`, `phone`, `company`, `job_title`,
`address`, `website`); the shell draws a small tag ("your email") after the ghost text and
never logs the text. The shell must ignore events whose `revision` is not its latest.

## macOS shell

### Threads

| Thread | Work |
|---|---|
| main | `AppDelegate` menus and windows (Settings, setup, instructions), `Controller` event handling, `GhostPanel`, insertion, statistics, Carbon hotkeys, power and session monitors, the pause timer, URLSession delegate |
| `foretype.ax` | `FocusTracker`: CFRunLoop with AXObserver sources, timers, all AX reads (80 ms global messaging timeout) |
| `foretype.keys` | `KeyTap`: both event taps; callbacks never block or call Accessibility |
| `foretype.screen` (queue) | Screen capture completion and Vision OCR |
| `foretype.caret` (queue) | Pixel caret captures and detection (blocking on ScreenCaptureKit; at typing pauses, or one capture for a new field, line or wrap) |
| `foretype.engine` (Rust) | Inference |

### Components (`mac/Sources/Foretype/`)

- **`FocusTracker.swift`**: follows the frontmost app (NSWorkspace activation), one
  `AXObserver` per app (focus, window, value, selection notifications on the app element
  and the focused element), a re-read burst 8 and 45 ms after each keystroke (from the
  listen tap), reads coalesced 2 ms, an idle poll every 0.5 s. Emits a `FieldSnapshot` only
  when its signature changed, with a monotonically increasing revision. Reads the text
  before the caret through `AXStringForRange` in a window of 3,000 UTF-16 units whose start
  is aligned to 1,024 (falling back to `AXValue`), the rest of the line (≤160), role,
  subrole, frame, marked range (`AXTextInputMarkedRange`, only length > 0 counts), window
  title and frame (on focus), and once per element its label/placeholder
  (`description`) and page URL (nearest `AXWebArea` with an http(s) `AXURL`). When
  `AXSelectedTextRange` is missing (some contenteditable editors) it reads through text
  markers instead (`AX.viaTextMarkers`; `FORETYPE_TEXT_MARKERS=1` forces it). In a web
  field (an `AXWebArea` above it), when `AXStringForRange` can't reach the last character
  of `AXNumberOfCharacters`, it is a Chromium contenteditable whose value and count have a
  newline between paragraphs that the ranges leave out (the ranges run paragraphs together
  and the caret's index falls one character early per paragraph): the text before the caret
  read through the ranges is aligned with `AXValue` (`AX.valueIndex`, ≤ 50,000 characters)
  and the text and caret index are taken from the value. Chromium's empty contenteditable
  (`<p><br></p>`) reads as a newline with the caret after it; it is read as empty.
  `field_key = pid << 32 ^ CFHash(element)`. Primes Chromium
  (`AXEnhancedUserInterface`) and Electron (`AXManualAccessibility`) apps per the compat
  DB and restores the flags on quit. Chrome turns on web content only after the flag has
  stayed set for 2 s (a clear inside that window cancels it), so the flag is set once per
  process and kept; it is checked again 0.5 s later (Chrome sometimes clears it as it
  activates) and while the app shows no focused element, and set again only when it reads
  `false`. With `FORETYPE_ONLY_APPS` (bundle IDs or pids), other apps are never read or
  primed. Electron updates a field's text a few milliseconds before its caret index: a
  snapshot whose only change is text after an unmoved caret (`caretLags`) is held once and
  the field read again 17 ms later. `stop()` (pause) removes the poll timer, the AXObserver
  and the activation observer; the thread stays, kept alive by a run-loop source that never
  fires, so it sleeps with no wakeups. `start()` adds them again and reads the focused field
  afresh (priming its app again if needed).
- **`Speller.swift`**: on the AX thread, asks `NSSpellChecker` (language left to the
  checker, so it follows the user's languages and learned words) whether the partial word
  is a word, can still become one (`completions`), or is a typo, and for a word just
  finished with a space whether it is misspelled and its correction. Verdicts are cached;
  secure fields are never checked. The core applies the policy.
- **`AppleModel.swift`**: Foundation Models as the `shell` backend's completer (offered
  in "Use a Server Instead…" when Apple Intelligence is available).
- **`Caret.swift`**: `CaretResolver` reads both the zero-length `AXBoundsForRange` and the
  previous character's trailing edge, validates each (origin zero, zero or huge height,
  equal to the field frame, outside the field, off-screen, too wide for one character) and
  prefers the previous-character edge. When the two disagree by more than half a line with
  the zero-length rect higher, that's the TextKit bug: it learns a per-app offset and uses
  it at line starts. Zero-length lower means a soft wrap. `font()` reads `AXFont` of the
  character before the caret (one `AXAttributedStringForRange` over the last ≤ 24): the
  family wins over a fake name (Word); size-only (Chrome) goes to `FontMatcher`, which picks
  the family whose rendering of the measured run matches its on-screen width. The font is
  scaled when the run (≥ 6 characters) is more than 25% wider or narrower on screen than in
  it (a zoomed document whose app reports the unzoomed size: LibreOffice), unless the scaled
  size would not fit the run's line. The run (`measurableRun`) is the characters before the
  caret after the last newline or tab, in the same `AXFont` as the one before the caret
  (text typed at 12 pt after 20 pt text), and on the caret's visual line: a range across a
  soft wrap is as wide as the line (TextEdit: 773 pt for 24 characters, read as a 3.9× zoom),
  so when its rect is ≥ 1.5 character heights tall a binary search over the characters'
  rects keeps those on the caret's line. `FocusTracker` reads the font when the caret
  arrives (another field or line, or a move that isn't typing: a click, an arrow, a
  deletion) and again on each of the first 6 characters typed there, since typed text can
  be in other attributes than the text before it (TextEdit's plain text set to 20 pt by a
  script still types at 12 pt); then it keeps it while typing goes on. A snapshot whose
  caret didn't move doesn't count (Electron's text arrives before its caret).
  When it finds no caret, the controller asks the pixel caret locator (below).
- **`PixelCaret.swift`**: the pixel caret locator, for fields where `CaretResolver` finds
  nothing (Teams, LibreOffice) or the app's rule says `"caret": "pixel"`. It captures only
  the field's rectangle (or the window, for apps whose field frame turned out not to contain
  the caret) of the app's own window with `SCScreenshotManager` (the pointer and Foretype's
  overlay are never in it), converts it to bytes and drops the image. Two detectors share a
  bar finder (column runs of set pixels merged into bars ≤ 3.5 pt wide, ≥ 3× as tall as
  wide, ≥ 75% filled, clear columns either side):
  - *blink*: captures every 120 ms for up to 1.3 s and keeps each pixel's colour range;
    pixels that changed by ≥ 48 form the caret, the only thing that toggles. It must be the
    one candidate, with little else changed around it (typing during the captures fails
    this). It learns the caret's look: colour (the extreme farther from the background,
    from fully covered pixels), width, height.
  - *verify*: one capture of ±16–80 pt around a predicted x (up to 3, 250 ms apart, to span
    an off phase), looking for a bar of the learned colour and 85–115% of the learned
    height; glyph stems are shorter than a line. The nearest one wins.
  The x is the intensity-weighted centre (median per column, so a neighbouring glyph's ink
  doesn't pull it), sub-pixel. `PixelCaretProvider` keeps one estimate per field (x, y,
  height, the caret line's start index and text, the look, a width scale, the field
  origin). `caret(for:)` (AX thread, every snapshot) returns it advanced by the width change
  of the line's text before the caret, in the host font (or GhostPanel's fallback font)
  times the learned width scale; nil on another line or past the field's edge. `note()`
  (before the snapshot is submitted) schedules work on the `foretype.caret` queue; a newer
  snapshot cancels it. With a position on the same line: verify 0.25 s after the text
  changed (blink if that fails). With none (a new field, another line, a wrap) and the
  app's caret look known (the last one learned in that app, kept in memory): a *solid*
  search 40 ms later, one capture of the field, or of four caret heights either side of the
  last position, for every bar of that look (`staticBars`). The caret is solid while the
  user types, so no pause is needed. `PixelCaret.choose` picks the bar: the only one without
  a position; else the nearest row below (a new line, a wrap) or above (the caret went back
  a line) that has any, and there the leftmost at a line start, the rightmost when nothing
  follows the caret on its line, or the only one. Within max(40 pt, 3 caret heights) of the
  field's right edge the same search runs on each change (the host may wrap the word being
  typed): a bar near the prediction on the same row re-anchors, else the next row's. A miss
  isn't retried for 0.3 s and falls back to a blink at the next pause. With no look yet: blink
  0.15 s after focus moves to a new field (empty ones too) or 0.5 s after the caret changed
  line. A result updates the estimate, learns the width scale from the observed travel
  (≥ 30 pt, ratio 0.6–1.6) and moves a visible suggestion. If AX had a previous-character
  rect that only the frame check rejected (`edgeOutsideFrame`), the blink search starts on
  that line, and a hit within 1.5 pt of it counts as a match; after two in a row
  `CaretResolver` skips the frame check for that app (LibreOffice), so AX places the caret
  again with no captures.
- **`GhostPanel.swift`**: borderless, non-activating, click-through `NSPanel` at
  `.statusBar` level, on all Spaces, excluded from Accessibility. Draws the words that fit
  before the field's right edge in the host font, gray; when not even the first word fits
  (the line is about to wrap), the first word runs past the edge. Without a caret rect (AX
  gave none and the pixel locator has no position yet) it shows a "mirror card"
  (⇥ suggestion) above the field, or below it when above would leave the field's display. `advance` shifts the ghost after an accept until the host reports the new
  caret. Mid-line suggestions show as a card just under the caret (inline ghost text would
  overlap the rest of the line); `showHint` shows a tip card for 8 s without turning on the
  key tap.
- **`KeyTap.swift`**: a permanent listen-only session tap (notices typing) and a consuming
  head-inserted session tap that is enabled only while a suggestion is visible (disabled 50
  ms after it hides, so the last synthetic key drains). Consumes Tab (next word), the key
  above Tab (` on ANSI, § on ISO: accept all), Esc (dismiss), Option+Tab (real Tab), and
  swallows their key-ups. Ignores events carrying the inserter's marker. Re-enables itself
  on `tapDisabledByTimeout`. `stop()` (pause) turns both taps off, so macOS delivers no key
  events at all; `start()` turns the listen tap back on.
- **`Inserter.swift`**: keystrokes posted at the annotated session tap with marker
  `0x46545950` ("FTYP"), at most 20 UTF-16 units per event on virtual key 0, Return for
  newlines. Paste: snapshot the pasteboard, write the text plus nspasteboard.org transient
  markers, Cmd-V on the layout's V key, restore after 250 ms unless the user copied
  meanwhile; only if `NSPasteboard.accessBehavior == .alwaysAllow` (macOS 15.4+).
  `deleteBackward(n)` sends Backspace `n` times (replacements: emoji, autocorrect).
- **`Controller.swift`**: wires everything. On the AX thread it adds the cached screen text
  to each snapshot, puts in the pixel caret estimate where AX gave no caret (or the rule
  says `pixel`; only with Screen Recording, screen context on and screen context allowed for
  the field), applies force (per field and line) and snooze, adds the speller's verdicts,
  shows one-time hints (Google Docs without screen-reader support; Arc and Dia without Text
  Metrics), submits, and asks the screen and caret providers for a refresh. On the main
  thread it drops events whose revision is stale, shows or hides the panel (and moves it
  when a new pixel position arrives for the same revision, keeping a mid-line card a card;
  a suggestion with no caret is held back while a solid search runs and shown when it
  reports: inline, or the card on a miss), toggles the consuming tap, and
  performs key actions. If an accept finds no suggestion (it went stale), it gives the key
  back; a replacement's text is deleted before the insert, and an accept that inserts text
  is counted in `UsageStats`. The engine can be swapped at runtime (`replaceEngine`) when
  the model or server changes. `setPaused(true)` hides the panel and stops the key taps,
  the tracker, pending pixel-caret and screen captures (and forgets the screen text), puts
  the Chromium/Electron flags back (`restorePrimedApps`) and sends `paused` to the core;
  `setPaused(false)` reverses it. `coreSettings` adds the runtime part of the core's
  settings: `paused`, and for `saveEnergy` greedy decoding, no prefetch, an 80 ms mid-word
  debounce and `unload_after_s` 60 (otherwise beam 3, prefetch, no debounce, 300 s); screen
  context is off while saving energy. Per-app pauses (`snooze`) end at a time or, with
  `Date.distantFuture`, when the app's last process quits.
- **`ScreenContext.swift`**: on a new field (50 ms) or after a 1.5 s typing pause at most
  every 15 s: `SCShareableContent` → the focused window (matched by pid and frame) →
  `SCScreenshotManager.captureImage` → Vision `.accurate` OCR → lines grouped into rows,
  rows inside the field dropped, rows nearest the field kept (rows above first, budget
  1,400 characters) in reading order. The new text is prefilled with `warm` right away.
  Skipped for secure input, secure fields and apps where suggestions are off. The image is
  discarded after OCR. The capture scale is the window's own display's
  (`SCContentFilter.pointPixelScale`), so a window on a 1x display isn't captured at 2x.
- **`ScreenGeometry.swift`**: the two coordinate spaces as pure functions. Global (Quartz)
  coordinates have their origin at the primary display's top-left with y down; AX
  positions, `CGDisplayBounds` and ScreenCaptureKit's `SCWindow.frame` use them. Cocoa
  coordinates (`NSScreen`, `NSWindow`) have it at the primary's bottom-left with y up. A
  display left of or above the primary has negative global x or y. `cocoaRect(fromGlobal:)`
  flips around the primary's height (the ghost panel's frame), `displayIndex(for:in:)` is
  the display showing most of a rect (or the nearest), `scale(for:in:)` its backing scale,
  and `cardY` puts a card above a field unless that leaves the field's display. Never
  compare a global rect with an `NSScreen` frame. `--geometry-selftest` checks them on
  made-up layouts (displays left, above, below and right of the primary, 1x and 2x).
- **`Hotkeys.swift`**: Carbon `RegisterEventHotKey`: Ctrl + key above Tab forces
  suggestions on the current line; Ctrl+Opt+Cmd + key above Tab pauses the app for 5
  minutes. Both are ignored while paused.
- **`Power.swift`**: `PowerMonitor` follows the power source and battery charge
  (`IOPSNotificationCreateRunLoopSource`; `IOPSCopyPowerSourcesList` for the internal
  battery's `kIOPSCurrentCapacityKey`/`kIOPSMaxCapacityKey`), Low Power Mode
  (`NSProcessInfoPowerStateDidChange`) and the thermal state
  (`thermalStateDidChangeNotification`): notifications only, no polling. `SessionMonitor`
  follows `NSWorkspace` will-sleep/did-wake, screens-did-sleep/wake and session
  resign/become-active, and the distributed `com.apple.screenIsLocked`/`Unlocked`; on wake
  it reads `CGSSessionScreenIsLocked` so a Mac that locks on sleep does not resume for a
  moment.
- **`Pause.swift`**: `PauseState`, the reasons to pause, any one enough: the user's pause
  (`pausedUntil` in UserDefaults, `Date.distantFuture` for until resumed; a run-loop timer
  ends it, rechecked on wake since timers don't count sleep; a saved `enabled = false` from
  before pausing becomes until resumed), power reasons (`thermal`, `batteryLow`, `lowPower`,
  `battery`; "Resume Anyway" sets the current ones aside until they end or the Mac is
  plugged in, and a new one pauses again), and system reasons (`sleep`, `lock`,
  `displaySleep`; never set aside). `PowerPolicy.decide` turns the power state and the
  three settings into pause reasons and `saveEnergy` (thermal `serious` saves energy,
  `critical` pauses; reasons set aside save energy). `PauseChoice` is the menu's lengths.
  `--pause-selftest` checks the rules, set-aside, the migration and the saved pause in a
  defaults suite of its own.
- **`AboutYou.swift`**: `AboutYou` (the user's details, master switch, writer-line
  switch (on by default), per-detail switches; `coreJSON()` sends switched-off details empty),
  `AboutYouStore` (`~/Library/Application Support/Foretype/about-you.bin`: the JSON sealed
  with CryptoKit ChaCha20-Poly1305, mode 0600; 256-bit key in the Keychain account
  `about-you-key`, created on the first save, read at launch only if the file exists;
  emptying every field or Clear All deletes both), `MeCard` (Contacts' "me" card, read only
  when the user clicks Fill from My Card; hidden in a bare binary, which has no Contacts
  usage string). `AppDelegate` keeps the details in memory, sends them to the engine at
  once (`Controller.detailsJSON`, again after an engine swap) and saves 0.5 s after the last
  change. `--about-selftest` checks the JSON and the sealing with a key in memory.
- **`Settings.swift`**: `AppSettings` (UserDefaults: batteryMode, lowPowerMode, pauseBelowBattery, lengthWords,
  stopAtSentenceEnd, instructions, appInstructions, disabled/enabled apps,
  useScreenContext, personalize, strength, backend, backendURL, backendModel, modelPath,
  onboarded), `Keychain` (service `dev.foretype.Foretype`; accounts `history-key`,
  `backend-api-key`), `HistoryStore` (`~/Library/Application Support/Foretype/history.bin`),
  `ModelLocator`.
- **`Stats.swift`**: `UsageStats`, the words-saved counts: per accept, kind (Tab or
  accept-all), words, characters and keystrokes saved (characters minus the one accept key
  press). Totals plus one bucket per local day for the last 30 days, as one JSON value in
  UserDefaults (`usageStats`); no text and no app names. `--stats-selftest` checks it with
  in-memory storage.
- **`ModelManager.swift`**: catalog from the core, URLSession downloads with resume data
  (cancel pauses when the server allows resuming; resume data stays in memory, and
  discarding it, or quitting, deletes the temporary file it names), streaming SHA-256
  (CryptoKit) before moving into `Models/`. Lists the folder's GGUF and leftover `.part`
  files with their allocated size, totals its disk use, and deletes only GGUF or `.part`
  files directly inside it. Progress reaches the UI in 0.5% steps.
- **`PreferencesWindow.swift`**: the Settings window, an `NSTabViewController` in toolbar
  style that sizes the window to each pane (General, Personalization, About You, Apps,
  Model, Statistics; programmatic `NSStackView`/`NSGridView` layout). It changes settings through
  `PreferencesHost`, which `AppDelegate` implements with the menu's own code paths
  (`Controller.applySettings`, `startEngine`/`replaceEngine` for model and server changes).
  The menu calls `refresh()` after its own changes so both stay in step.
- **`OnboardingWindow.swift`**, **`InstructionsWindow.swift`**, **`AppDelegate.swift`**:
  setup checklist (Accessibility, Screen Recording, model), custom instructions, the
  menu-bar menu (keystrokes saved today, why and until when it is paused, Pause ▸ or
  Resume / Resume Anyway, length and sentence end, per-app toggle and Pause in *app* ▸,
  screen context, personalization, instructions, model with sizes on disk and Delete a
  Model, server, Settings, setup, updates). The status item's menu is attached only while
  it opens, so the button sees the click first: Option-click toggles the pause. The
  `foretype://` URL scheme (`CFBundleURLTypes`, bundled app only) takes `pause`,
  `pause?minutes=N`, `resume` (the user's pause only) and `toggle`. `AppDelegate` wires the
  monitors to `PauseState` and pushes the result to `Controller.setPaused`/`saveEnergy`,
  the icon (with a tooltip naming the reason) and Settings; a core created while paused gets
  `paused: true` in its first settings, so it never starts loading the model. A hidden main menu gives Foretype's windows
  Cmd-, (Settings), Cmd-W, Cmd-Q and the editing keys; accessory apps show no menu bar but
  still route key equivalents through it. The setup window opens when Accessibility or a
  model is missing, and on the bundled app's first run.
- **`Icons.swift`**: the menu-bar glyph, drawn in code as an 18 pt template image, one
  picture per state (`MenuBarIcon.set(.active / .paused / .powerPaused / .loading / .error)`);
  `AppDelegate` shows `.paused` for the user's or the system's pause, `.powerPaused` when
  only the power rules pause, and otherwise maps the engine state (ready, idle or paused →
  active, starting or loading → loading, setup, waiting or error → error). `badge: true`
  adds a dot in the top-right corner while an update waits to be looked at.
  Also gives a bare dev binary the checkout's `mac/Resources/AppIcon.icns` as its icon.
- **`UpdateController.swift`**: Sparkle 2 when built with `FORETYPE_SPARKLE=1` and the
  Info.plist has `SUFeedURL` and `SUPublicEDKey`; otherwise a no-op. Installs a silent
  download once the user is idle, and tracks an update found but not installed
  (`availableVersion`, kept in the defaults across launches; cleared when a check finds none,
  the user skips it or it is installed) and whether a scheduled check is waiting to be looked
  at (`needsAttention`). As Sparkle's standard user driver delegate it takes over scheduled
  updates (gentle reminders): no window, the menu-bar icon's dot instead. `AppDelegate` shows
  the menu line "Update Available: X.Y.Z — Install…" and Settings ▸ General the "Version X.Y.Z
  is available" row; both open Sparkle's window (`checkForUpdates`).
- **`AX.swift`**: typed AX helpers and the debug logger.
- **`Localization.swift`**: `L(_:)`, `L(_:_:)` and `LCount(_:_:one:)`, the lookups for every
  user-visible string. See *Localization* below.

### Localization

Every string the user sees goes through `L("English text")` (or `L("Format %1$@ … %2$@",
args…)`), which is `Bundle.main.localizedString(forKey:value:table:)` with the English text
as both key and fallback. Translations are plain files in the repo,
`mac/Localization/<lang>.lproj/`:

- `Localizable.strings`: one line per key, `"English" = "translation";`. Formats number
  their arguments (`%1$@`, `%2$@`) so a translation can reorder them; every argument is a
  string, numbers and percentages are formatted first (`formatNumber`, `formatPercent`:
  `NumberFormatter` in the current locale, so Indian grouping and the locale's digits).
- `Localizable.stringsdict`: counted nouns and sentences (`LCount(n, "%@ files", one: "%@
  file")`). The entry receives the count as `%1$ld`, which only picks the plural form, and
  the formatted number as `%2$@`. `en.lproj` has one too; a bare binary without it falls
  back to the two English forms in the call.
- `InfoPlist.strings`: `NSAccessibilityUsageDescription`.

`scripts/build-mac.sh` copies each `.lproj` into `Foretype.app/Contents/Resources/` before
signing and lists them in `CFBundleLocalizations` (`CFBundleDevelopmentRegion` is `en`).
It is not a SwiftPM resource target: SwiftPM would place `Foretype_Foretype.bundle` at the
app's top level, where code signing rejects it, and `Bundle.module` would look there. A bare
`mac/.build/release/Foretype` has no `.lproj` next to it, so every lookup returns the key
and the app runs in English. macOS picks the language (System Settings ▸ General ▸
Language & Region, per app under Applications); AppKit's own buttons and panels follow it.
Not localized: debug logs, self-test output, text from the core (its error messages and
the model path while loading; the one fixed idle detail, "model unloaded", is mapped in the
shell), catalog model names and licenses, emoji shortcodes, Keychain item labels (stored
data), Google Docs' and Chrome's own setting names in the tip cards.
`scripts/check-localization.py` checks that every key in the code has a translation with
the same placeholders.

## Cross-app context: hook points for Phase B

The collector of `docs/ROADMAP.md` ("Cross-app context", D42) reads windows of apps other
than the focused one. Where it must plug in:

- **Which apps may be read.** `AppSettings.onlyAppsAllow(pid:bundleId:)` is today's gate
  for the focused app (`FocusTracker` never reads or primes an app it rejects, and
  `Controller.screenContextAllowed` checks it before OCR). The collector must call it for
  every candidate window's owner (`SCWindow.owningApplication` pid and bundle ID, or the AX
  application's pid) *before* reading any text, by AX or OCR, so that with
  `FORETYPE_ONLY_APPS` set a development build reads nothing outside the listed apps,
  including as context. The core's `only_apps` can't do this: it only filters snapshots by
  bundle ID (and is empty when the list holds a pid), and context text would reach it
  already read. A test that needs a source app lists it too
  (`FORETYPE_ONLY_APPS=com.apple.mail,com.microsoft.Word`).
- In the same place: the never-read list (password managers by default), the user's
  per-app opt-outs and disabled apps, secure input (`IsSecureEventInputEnabled`) and
  Foretype's own windows; the feature's setting; and the backend (no reading at all for
  `llama-server` and `openai`).
- **Coordinates.** Windows on every display come from `SCShareableContent` in global
  coordinates; use `ScreenGeometry` for anything that meets `NSScreen` or `NSWindow`.
  `onScreenWindowsOnly` lists each display's current Space only, so windows on other Spaces
  (and minimized ones) are invisible: the recently-viewed pool has to keep what was read
  while they were on screen.
- **Lifetime.** `ScreenContextProvider.reset()` (pause) is where the pool is cleared too,
  along with screen lock and sleep (`SessionMonitor`).

## Data and privacy

| Data | Where it goes |
|---|---|
| Text of the focused field | In memory; into the prompt. Never logged unless `FORETYPE_DEBUG` (suggestions only) |
| Screen text (OCR) | In memory per field; image discarded immediately |
| Writing history (opt-in) | `history.bin`, encrypted, key in the Keychain; deleted from the menu |
| Your details (About You) | `about-you.bin`, encrypted, key in the Keychain; in the core's memory for fills; in the prompt only with the writer line on and a local model; never logged: debug logs name a fill's detail, not its value, and both the core (`UserDetails::redact`) and the shell (`Log.mask`) print every run of 4+ letters or digits of a value as `***` in other logged text, since a model suggestion can echo a detail from the document; Clear All deletes file and key |
| Contacts | Your own card, read once when you click Fill from My Card |
| Statistics | Counts only (accepts, words, characters, keystrokes saved; per day for 30 days and in total) in UserDefaults `usageStats`; reset in Settings |
| Clipboard | Read only to restore it after a paste, only with "always allow" access |
| Network | Model downloads (Hugging Face), Sparkle update checks (release builds), and the user's own server if one is configured. Nothing else |
