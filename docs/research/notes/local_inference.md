# Local Inference for a System-Wide Prose Autocomplete App on Apple Silicon (as of Oct 2026)

Scope: the inference side only (runtimes, models, prompts, latency, mid-word handling, personalization, cloud/BYO backends, lessons from code-autocomplete tools). Research date: 2026-10-18. Every number carries its hardware and date where the source gave one. Rough estimates I derived myself are labelled as inferences.

---

## 1. Runtimes on macOS and how to embed them in a Swift app (llama.cpp, MLX, Ollama, Core ML / Core AI, Apple Foundation Models), plus licensing

### Takeaway
llama.cpp is the proven default for a shipping prose-autocomplete app. Cotypist (the commercial reference product) uses it, and so do the open-source clones Cotabby, tabby (Joaov41) and KeyType. You can embed it in-process through the official `llama.xcframework` and a Swift wrapper, or run `llama-server` as a helper process. MLX (mlx-swift-lm) is the main alternative: it is usually faster at decode for small models but has a less mature prompt/KV-cache reuse story for this workload. Apple's Foundation Models framework is a poor fit for keystroke-level ghost text. It uses an instruction/session API with a 4096-token context, runs at about 20–30 tok/s, applies guardrails, and rate-limits background processes on battery.

### Cited Findings

**Reference products and their runtimes**
- Cotypist (closed-source, launched May 27, 2026) lists "llama.cpp + Gemma 4", with Gemma 4 as the default model. It uses about 1–2.5 GB RAM, requires macOS 14+ and Apple Silicon, and makes no cloud calls. Tiers: Free (daily limit), Plus $8/mo, Pro $12/mo. — [Cotypist press kit](https://cotypist.app/press)
- Cotabby (open source, AGPL-3.0) runs local GGUF **base** models in-process through llama.cpp (via its "CotabbyInference" module). It also has an Apple Intelligence (Foundation Models) engine on macOS 26+ and an OpenAI-compatible engine. The open-source engine needs macOS 14+. — [FuJacob/cotabby GitHub](https://github.com/FuJacob/cotabby)
- tabby (Joaov41) is a menu-bar app that runs GGUF models in-process through llama.cpp via llama.swift. It is AGPL v3, in beta, and needs Accessibility and Input Monitoring permissions. — [Joaov41/tabby](https://github.com/Joaov41/tabby) (via search summary)
- KeyType (johnbean393, MIT) has a `ModelRuntime` package described as a "llama.cpp wrapper", a "sectioned, budgeted prompt builder", and a `ConstrainedGeneration` package doing "logit masking, trie admissibility, search". It requires macOS 14+. — [johnbean393/KeyType](https://github.com/johnbean393/KeyType)
- TabType (nilava) uses MLX rather than llama.cpp (MIT). GhostType (mk668a) uses no in-process engine; it talks to an external OpenAI-compatible server (llama.cpp, LM Studio, Ollama) and is licensed PolyForm Noncommercial. — [search summary: TabType release](https://newreleases.io/project/github/nilava/TabType/release/v0.1.0), [GhostType mirror](https://ithub.global.ssl.fastly.net/mk668a/GhostType)

**llama.cpp embedding**
- Each llama.cpp release publishes a prebuilt `llama.xcframework` with Metal support. It targets iOS 16.4+ and macOS 13.3+ and can be dragged into "Frameworks, Libraries, and Embedded Content". — [Liquid AI llama.cpp mobile docs](https://docs.liquid.ai/deployment/on-device/llama-cpp/mobile)
- `mattt/llama.swift` gives semver-tagged SPM access to the upstream XCFramework. `StanfordBDHG/llama.cpp` repackages it for SPM but requires C++ interop in the consuming project. — [mattt/llama.swift](https://github.com/mattt/llama.swift), [StanfordBDHG/llama.cpp on Swift Package Registry](https://swiftpackageregistry.com/StanfordBDHG/llama.cpp)
- llama.cpp is MIT-licensed; models run through it keep their own licenses. — [Picovoice blog](https://picovoice.ai/blog/local-llms-llamacpp-ollama/) (secondary; confirm against the repo LICENSE)
- Server mode features that matter for autocomplete (from the current `tools/server/README.md`):
  - `cache_prompt` defaults to `true`. It reuses the KV cache from the previous request so only the differing suffix is processed. The docs warn it can make results nondeterministic.
  - `--cache-reuse N` (default 0) reuses chunks via KV shifting.
  - `n_predict: 0` evaluates the prompt into the cache without generating, which is useful for prefill warm-up.
  - `t_max_predict_ms` is a time cap that fires after a newline is generated; the docs suggest it for FIM.
  - `stop` takes an array of strings. `n_probs` returns top-N token probabilities. `id_slot` pins a request to a slot.
  - `POST /slots/{id}?action=save|restore` works with `--slot-save-path`. `--cache-ram` defaults to 8192 MiB. `-ctxcp` defaults to 32 checkpoints per slot. `--parallel` sets the number of slots, and continuous batching is on by default.
  - `/infill` takes `input_prefix`, `input_suffix` and `input_extra`.
  - Speculative decoding: `--spec-type` (`draft-simple`, `draft-eagle3`, `ngram-simple`, `ngram-mod`, …), `-md` draft model, `--spec-draft-n-max` default 3.
  — [llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

**MLX / mlx-swift-lm**
- `ml-explore/mlx-swift-lm` is a Swift package for LLM/VLM apps on MLX with Hugging Face loading. Its `MLXLMCommon` module provides `ModelContainer`, `ChatSession` and `KVCache` (including `RotatingKVCache` and KV quantization). It also lists LoRA/DoRA fine-tuning and "wired-memory coordination" as features, and installs as SPM (e.g., tag 2.29.1). — [mlx-swift-lm (Algolia docsearch)](https://docsearch.algolia.com/mcp/docs/repo/ml-explore/mlx-swift-lm), [skills.sh mlx-swift-lm summary](https://www.skills.sh/ml-explore/mlx-swift-lm/swift-mlx-lm)
- Python `mlx-lm` has prompt caching (`mlx_lm.cache_prompt`, `--prompt-cache-file`) and a rotating fixed-size KV cache (`--max-kv-size`). It requires macOS 15.0+, wires model and cache memory, and the wired limit can be raised with `sudo sysctl iogpu.wired_limit_mb=N`. — [mlx-lm README](https://github.com/ml-explore/mlx-lm/blob/main/README.md)
- On M5, MLX uses the GPU "Neural Accelerators" only on macOS 26.2+. MLX Swift shares its core library with the Python front-end. — [Apple ML Research, "Exploring LLMs with MLX and the Neural Accelerators in the M5 GPU" (Nov 2025)](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)
- MLX is MIT-licensed. — [tds.s-anand.net MLX notes](https://tds.s-anand.net/2026-02/docs/week-2/11-local-llms-4-mlx-labs/) (single, less authoritative source)

**Ollama**
- Ollama 0.19 (preview, March 30, 2026) moved its Apple Silicon backend to MLX. — [lilting.ch](https://lilting.ch/en/articles/ollama-mlx-apple-silicon-preview); [yage.ai summary](https://yage.ai/share/mlx-apple-silicon-en-20260331.html)
- The Ollama wrapper adds a lot of overhead. On an M4 Max (128 GB), raw llama.cpp (Metal) reached 89.4 tok/s against Ollama's 43.5 tok/s on the same model (GitHub ollama #14861, as cited by yage.ai). The article argues the headline "MLX is 3x faster" claims mostly reflect this overhead. — [yage.ai](https://yage.ai/share/mlx-apple-silicon-en-20260331.html)

**Apple Foundation Models (macOS 26) / Core AI (macOS 27)**
- Model: an approximately 3B-parameter on-device model with 2-bit quantization-aware training and KV-cache sharing. The second block (37.5% of layers) reuses the first block's KV cache, cutting KV memory by 37.5% and reportedly cutting TTFT by about 37.5%. — [Apple Intelligence Foundation Language Models Tech Report 2025 (arXiv 2507.13575)](https://arxiv.org/pdf/2507.13575v2); TTFT figure only via [HackerNoon repost](https://hackernoon.com/apple-quietly-built-a-new-ai-stack-and-it-runs-on-your-device)
- Context: 4096 tokens per `LanguageModelSession`, covering instructions, prompts, tools and outputs. Exceeding it throws `exceededContextWindowSize`. OS 26.4 added `contextSize` and `tokenCount(for:)`. — [Apple TN3193](https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md), [InfoQ (Mar 2026)](https://infoq.com/news/2026/03/apple-foundation-models-context)
- Speed: an Apple developer-relations engineer said that if throughput is "consistently much worse than 20~30/s" developers should file feedback. They recommended prewarming. Another developer saw 20+ s latency that turned out to be schema compilation, not decoding. — [Apple Developer Forums thread 791993](https://developer.apple.com/forums/thread/791993)
- Rate limiting: an Apple Frameworks Engineer said rate limiting applies "when your device is on battery AND when your process is running in the background". They recommended `respond` over streaming in the background. The thrown error can misleadingly say "guardrail" when the cause is the rate limit. — [Apple Developer Forums thread 789788](https://developer.apple.com/forums/thread/789788)
- Guardrails: developers report frequent false positives, for example on news articles that mention deaths or politics. — [Forums thread 787736](https://origin-devforums.apple.com/forums/thread/787736), [Forums thread 792888](https://developer.apple.com/forums/thread/792888)
- Adapters: LoRA adapters of about 160 MB each. Deploying them requires the "Foundation Models Framework Adapter Entitlement". Each adapter works with only a single system-model version, and training needs an Apple Silicon Mac with 32 GB or more. Adapter training toolkit "Version 26.0.0 is the last release and isn't compatible with macOS … 27 and later." — [Apple Foundation Models adapter page](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)
- macOS 27 (WWDC26, beta June 8, 2026):
  - Foundation Models now accepts "any language model … that conforms to the Language Model protocol" (Apple, Claude, Gemini, etc.).
  - It adds multimodal prompts and "Dynamic Profiles".
  - Private Cloud Compute access is free for Small Business Program apps with fewer than 2M first-time downloads.
  - The new **Core AI** framework is a memory-safe Swift API to "load, specialize, and run AI models entirely on-device", with ahead-of-time compilation and stateful execution.
  — [Apple "What's new in macOS 27"](https://developer.apple.com/macos/whats-new/)
- A Gemma 4 E2B model has already been converted to Core AI's `.aimodel` format on Hugging Face. — [visible-cx/gemma-4-E2B-CoreAI](https://huggingface.co/visible-cx/gemma-4-E2B-CoreAI)
- A third-party Core ML conversion of Qwen3.5-0.8B targeting the Apple Neural Engine exists. — [leok7v/Qwen3.5-0.8B-coreml](https://huggingface.co/leok7v/Qwen3.5-0.8B-coreml)

### Inferences
- **Recommended stack:** embed llama.cpp in-process via `llama.xcframework` (MIT), wrapped in Swift (llama.swift or a thin C-API wrapper). This keeps everything on one KV state you control and avoids HTTP overhead. Expose `llama-server`, Ollama and LM Studio only as optional external backends.
- In-process llama.cpp also gives you direct access to the sequence-state save/restore primitives you need for hybrid/SWA models (see Q4). The server's chat-oriented checkpoint policy may not suit per-keystroke requests.
- MLX via mlx-swift-lm is a credible second backend. It is likely faster at decode for sub-2B models and fits naturally if you want on-device LoRA training in the same process. Validate prefix-cache trimming (rolling back the KV cache to the common prefix) before choosing it.
- Ollama should not be a hard dependency. It needs a separate install and daemon, it adds wrapper overhead, and it gives no fine control over KV reuse. It is fine as a BYO backend.
- Apple Foundation Models is a nice zero-download fallback, but it is unsuitable as the primary engine:
  - An autocomplete app runs as a background, accessory-style process while the user types in another app, so it is exactly the case Apple rate-limits on battery.
  - At about 20–30 tok/s, a 10-token suggestion takes about 330–500 ms before prefill.
  - Guardrail false positives would silently drop suggestions.
  - The documented API is session/instruction-based with no raw-continuation entry point. I found no documentation of a raw completion mode.
- Core AI (macOS 27) could become a first-party "bring your own model" runtime. It is too new to benchmark, and it would limit the app to macOS 27+.

### Gaps
- I could not confirm Ollama's license (widely understood to be MIT) or mlx-swift-lm's license file in this session.
- I found no documentation of whether Foundation Models (macOS 26 or 27) exposes a raw, non-chat text-continuation mode, or what its TTFT is for short prompts on Macs.
- I found no published benchmark of Core AI LLM inference speed.
- I did not verify whether llama-server cancels generation on client disconnect; the README section was truncated.

---

## 2. Model choice for prose continuation (base vs instruct, candidate models, multilingual, quantization)

### Takeaway
Use small **base** (pretrained, non-instruct) models in pure continuation mode. In late 2026 the practical shortlist is:
- Qwen3.5 Base: 0.8B / 2B, Apache 2.0, 2026, hybrid Gated DeltaNet.
- Qwen3 Base: 0.6B / 1.7B / 4B, Apache 2.0, dense, 119 languages.
- Gemma 4 E2B / E4B: Apache 2.0 since April 2026. Cotypist's default is Gemma 4.
- Gemma 3 270M for an ultra-light tier.

For quantization, Q6_K/Q8_0 suits ≤1B models and Q4_K_M suits 2–4B. Cotabby's model tiers are a concrete, shipping reference.

### Cited Findings
- **Cotabby's shipping model lineup** (open-source engine, all base models):

  | Tier | Base model | Quant | Size |
  |---|---|---|---|
  | tabby-2-nano | Qwen3.5-0.8B-Base | Q6_K | ~0.8 GB |
  | tabby-2-mini | Qwen3.5-2B-Base | Q4_K_M | ~1.4 GB |
  | tabby-2-base | gemma-4-E2B | Q6_K | ~4.5 GB |
  | tabby-2-pro | gemma-4-E4B | Q4_K_M | ~5.0 GB |

  Cotabby "treats the model as a pure text continuer rather than an instruction-tuned chat model". — [FuJacob/cotabby](https://github.com/FuJacob/cotabby)
- Cotypist defaults to Gemma 4 via llama.cpp at about 1–2.5 GB RAM, and is "multilingual, with in-sentence code-switching". A press angle mentions "a 3 GB Gemma model". — [Cotypist press](https://cotypist.app/press)
- A review site claims larger models (e.g., Qwen) are Pro-only in Cotypist. I could not verify this against the developer. — [implicator.ai](https://www.implicator.ai/cotypist-the-german-indie-behind-ai-autocomplete-everywhere)
- **Qwen3.5 Small** (released March 2, 2026):
  - Sizes 0.8B / 2B / 4B / 9B, "along with their Base versions".
  - Apache 2.0, 262K context, native vision, hybrid thinking/non-thinking.
  - Artificial Analysis Intelligence Index: 0.8B = 9, 2B = 16, 4B = 27, 9B = 32.
  — [Artificial Analysis](https://artificialanalysis.ai/articles/qwen3-5-small-models), [Gigazine](https://gigazine.net/gsc_news/en/20260303-qwen-3-5-small)
- **Qwen3.5-0.8B architecture:** 24 layers in a 3:1 hybrid, 6 × (3 × Gated DeltaNet → FFN, then 1 × Gated Attention → FFN). That is 18 linear-attention (recurrent-state) layers plus 6 full-attention layers, with GQA 8 query heads / 2 KV heads. — [mlabonne, "Qwen3.5: Nobody Agrees on Attention Anymore"](https://medium.com/@mlabonne/qwen3-5-nobody-agrees-on-attention-anymore-4709e1bd014b), [dQwen3.5 paper (arXiv 2609.20751)](https://arxiv.org/pdf/2609.20751)
- **Qwen3-1.7B-Base:** 1.7B parameters, pretrained on 36T tokens covering 119 languages, 32,768 context, Apache 2.0. — [Featherless mirror of the Qwen model card](https://featherless.ai/models/Qwen/Qwen3-1.7B-Base/readme) (secondary; confirm on HF)
- **Gemma 4** (released April 2, 2026):
  - Sizes: E2B, E4B, 26B A4B and 31B. Google docs also list a 12B; sources disagree.
  - E2B is about 2.3B effective parameters (5.1B including Per-Layer Embeddings). E4B is about 4.5B effective (8B including PLE).
  - Base and "IT" variants are listed separately.
  — [Google Gemma docs](https://ai.google.dev/gemma/docs/core), [Simon Willison](https://simonwillison.net/b/9404), [llmreference](https://www.llmreference.com/model-family/gemma-4)
- Gemma 4 moved to **Apache 2.0**, replacing the custom Gemma Terms of Use. — [implicator.ai](https://www.implicator.ai/google-releases-gemma-4-under-apache-2-0-dropping-its-custom-ai-license/), [Gigazine](https://gigazine.net/gsc_news/en/20260403-google-released-gemma-4)
- **Gemma 4 E2B architecture:** 35 layers, GQA 8 query heads / 1 KV head, 512-token sliding window interleaved with global layers, 128K context, KV sharing in later layers. — [ApX Gemma 4 E2B](https://apxml.com/models/gemma-4-e2b), [Sebastian Raschka](https://magazine.sebastianraschka.com/p/recent-developments-in-llm-architectures), [Maarten Grootendorst visual guide](https://newsletter.maartengrootendorst.com/p/a-visual-guide-to-gemma-4) (the window size comes from one spec site only)
- **Gemma 3 270M:**
  - Pretrained and IT checkpoints were released together.
  - Of the 270M parameters, 170M are embeddings (large vocabulary) and 100M are transformer blocks.
  - Memory is about 550 MB.
  - Google's internal test: INT4 on a Pixel 9 Pro used 0.75% battery for 25 conversations.
  - It is aimed at fine-tuned narrow tasks.
  — [Google Developers Blog (Aug 2025)](https://developers.googleblog.com/introducing-gemma-3-270m/), [The Register](https://www.theregister.com/2025/08/15/little_llm_on_the_ram/)
- **Llama 3.2 1B/3B** uses the Llama 3.2 Community License. Licensees with more than 700M MAU need a separate license, there is a required attribution notice, and an Acceptable Use Policy applies. — [meta-llama/Llama-3.2-1B model card](https://huggingface.co/meta-llama/Llama-3.2-1b)
- **Quantization quality** (Llama-2 7B, llama.cpp PR #4739): average change versus FP16 was Q8_0 ≈ 0.06, Q6_K ≈ 0.1, Q5_K_M ≈ 0.3, Q4_K_M ≈ 1.0. Commenters observed that phi-2 (2.7B) shows "much higher divergences" than 7B-class models, suggesting small models quantize worse. — [llama.cpp PR #4739](https://github.com/ggerganov/llama.cpp/pull/4739)
- On Llama-3 8B, perplexity was Q8_0 6.234 versus Q4_K_M 6.407. — [bmdpat blog (2026)](https://bmdpat.com/blog/q4-k-m-vs-q8-0-which-gguf-quant-should-you-use-2026)
- A llama.cpp quantization guide mirror advises keeping more bits for ~1B models, because the size savings from aggressive quantization matter less. — [Mintlify llama.cpp quantizing guide](https://mintlify.com/ggml-org/llama.cpp/models/quantizing-models)
- Memory example: Qwen3-1.7B in MLX BF16 uses 4.40 GB (M4/M5 24 GB MacBook Pro test). — [Apple ML Research M5 post](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)

### Inferences
- **Base vs instruct:** both open-source clones that document their choice use base checkpoints as raw continuers (Cotabby explicitly). Instruct models tend to "answer" or add chat boilerplate, while base models continue in whatever register the preceding text sets. Ship base models by default. Keep an instruct model only for an optional "rewrite/instruction" feature.
- **Architecture affects caching.** Qwen3 (dense, full attention) is the easiest family for llama.cpp prefix reuse. Qwen3.5 (Gated DeltaNet recurrent layers) and Gemma 4 (SWA plus shared KV) give better quality per byte, but they need care with KV/state rollback (see Q4). Cotypist ships Gemma 4 on llama.cpp anyway, so it is clearly workable.
- **Suggested tiers** for an open-source app:
  - 8 GB Macs: Qwen3.5-0.8B-Base Q6_K, or Qwen3-0.6B-Base Q8_0.
  - Default: Qwen3.5-2B-Base or Qwen3-1.7B-Base at Q4_K_M/Q5_K_M.
  - Quality tier on 16 GB+: Gemma 4 E2B/E4B base.
  - All of these are Apache 2.0, which avoids Llama's license obligations.
- Phi-4-mini and SmolLM2/3 are possible but have no strong advantage. They are English-centric relative to Qwen/Gemma, and I did not verify their licenses this session.
- **Multilingual:** Qwen3 (119 languages) and Gemma 4 are the safest choices. A 270M model is likely too weak for open-ended multilingual prose without fine-tuning.

### Gaps
- I found no published head-to-head evaluation of small base models specifically on prose/email continuation quality, such as acceptance rate or keystrokes saved.
- I found no model fine-tuned specifically for prose autocomplete with FIM.
- I could not confirm SmolLM3 (believed Apache 2.0) or Phi-4-mini (believed MIT) licenses, or the official Gemma 4 base-checkpoint names, from primary sources.
- I found no direct Q4 vs Q8 KL measurements for 0.5–2B models.

---

## 3. Prompt construction (app/window context, text before and after the caret, FIM, user profile, voice, stopping criteria, completion length)

### Takeaway
Build a raw-text continuation prompt for a base model. Use a short, stable header (user name/profile/style notes, app and window context), then optional retrieved snippets of the user's own past writing, then the text before the caret, which goes last. Prose base models generally lack FIM training, so use text after the caret mainly as a gate (suggest only when little or nothing follows the caret) rather than as an FIM suffix. Cap generation at a few words to one sentence, with stop strings and a time cap.

### Cited Findings
- Cotabby conditions its base model on "the user's name, writing style, language, and on-screen context". Optional Screen Recording captures the area around the cursor for visual context. Generation is blocked in password/secure fields. — [FuJacob/cotabby](https://github.com/FuJacob/cotabby)
- KeyType uses a "sectioned, budgeted prompt builder" (`Prompting` package) and captures focus, caret and text-field snapshots via Accessibility (`MacContextCapture`). — [johnbean393/KeyType](https://github.com/johnbean393/KeyType)
- Cotypist "learns vocabulary, names, and phrasing across apps", with personalization data encrypted on-device. The method (fine-tuning vs in-context) is not disclosed. — [Cotypist press](https://cotypist.app/press)
- llama.vim (ggml-org) context layout:
  - `n_prefix` = 256 lines before the cursor and `n_suffix` = 64 lines after.
  - The current line's text before the cursor goes in `prompt` (after FIM_MID).
  - Extra context comes as `input_extra` chunks with text/time/filename.
  - `max_line_suffix` = 8: auto-trigger is skipped when more than 8 characters follow the cursor on the line.
  - `n_predict` = 128 and `t_max_predict_ms` = 1000.
  - Suggestions that repeat the suffix or following lines are filtered out.
  — [llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)
- llama-server `/infill` uses the model's FIM tokens. It uses the repo-level pattern if `FIM_REPO`/`FIM_FILE_SEP` exist; otherwise extra context is simply prefixed. — [llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- llama-server's `t_max_predict_ms` "fires after a newline has been generated". `stop` strings are excluded from the output, and `n_predict` caps tokens. — [llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- Apple Foundation Models' 4096-token window is shared by instructions, prompt and output, at about 3–4 characters per token for English and about 1 per token for CJK. — [Apple TN3193](https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md)

### Inferences
- **Recommended prompt skeleton for a base model:**
  1. A stable header that changes rarely, e.g. "The following is a {email|chat message|document} written by {Name} in {App} ({window title}). {Name} writes {style notes}."
  2. Two or three retrieved examples of the user's prior text in the same app or for the same recipient, framed as earlier messages.
  3. The current field's text before the caret, truncated from the front to a token budget (e.g., 256–1024 tokens).

  Put volatile items (window title, retrieved snippets) as late as possible but before the caret text. Keep the header byte-identical across keystrokes so KV-prefix reuse works (Q4).
- **Front truncation:** move the start of the before-caret window in coarse jumps, e.g. at paragraph or line boundaries, rather than sliding it per keystroke. llama.vim's line-based `n_prefix` behaves this way. A per-character sliding start would invalidate the entire KV cache on every keystroke.
- **Text after the caret:** adopt llama.vim's `max_line_suffix` heuristic (only auto-suggest when the caret is at or near the end of the line or paragraph). Optionally use the suffix to filter out suggestions that duplicate it. Only use true FIM (`/infill`) with a model that has FIM tokens (e.g., code models). I found no evidence that Qwen3 or Gemma base checkpoints are trained for prose FIM.
- **Voice:** for a base model, the strongest lever is in-context examples of the user's own writing. The next is a LoRA (Q6). Instruction-style "write like me" text matters less for base models.
- **Length and stopping:** use a short `n_predict` (about 8–24 tokens, i.e. a few words to one clause), stop strings on `\n` and optionally `. ` / `? ` / `! `, and a wall-clock cap of about 150–300 ms for the whole generation. Display up to the first sentence boundary and let the user accept word by word (llama.vim offers full/line/word accept keymaps). This also keeps per-keystroke compute and battery use low.

### Gaps
- I found no published evaluation of which context fields (app name, window title, recipient) measurably improve prose-completion acceptance.
- I found no prose-specific FIM model.
- Cotypist's exact prompt format is not public.

---

## 4. Latency engineering (TTFT targets, debounce, KV/prefix-cache reuse, cancellation, speculative decoding, power/thermal, residency, and measured benchmarks)

### Takeaway
On any Apple Silicon Mac, a ≤2B model at Q4–Q8 can produce a 5–15-token suggestion within about 100–250 ms, but only if the prompt prefix is already in the KV cache, so each keystroke prefills just a handful of new tokens. A cold prefill of 500–1000 tokens can take 0.5–2 s on base M1/M2-class chips. The core engineering therefore has four parts:
1. A stable prompt prefix plus KV reuse.
2. Prefill on focus change (an `n_predict=0` warm-up).
3. Debounce plus cancellation of stale requests.
4. A client-side suggestion cache that reuses a suggestion while the user types characters matching it.

Watch out for hybrid/SWA models (Qwen3.5, Gemma 4): llama.cpp cannot roll their state back arbitrarily.

### Cited Findings

**Latency targets used by real tools**
- Zed's Zeta edit prediction aimed for under 200 ms at the median and under 500 ms at p90. It found a 32B model incompatible with that budget and used n-gram-based speculative decoding (copying from input) for a significant speedup. — [Zed blog, "Zed now predicts your next edit with Zeta"](https://zed.dev/blog/edit-prediction)
- llama.vim:
  - The first request uses a 250 ms generation cap so it returns quickly. Later speculative requests use `t_max_predict_ms` = 1000.
  - `fim_debounce_ms` = 100: if a request is in flight, the next is rescheduled after 100 ms, and a new request stops the previous job.
  - `t_max_prompt_ms` = 500 exists but is marked "not yet supported".
  — [llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)
- Continue.dev debounces (it waits until the user stops typing) and reuses a cached completion when the cursor returns to a position already completed, e.g. after backspace. Its docs page does not give the default delay. — [Continue docs, How Autocomplete Works](https://docs.continue.dev/ide-extensions/autocomplete/how-it-works)

**KV/prefix cache reuse in llama.cpp**
- `cache_prompt` (default true) processes only the differing suffix. `--cache-reuse N` (default 0) enables KV shifting to reuse chunks even when the prefix is not identical. llama.vim's sample server invocation uses `--cache-reuse 256` and notes it "dramatically improves the performance at large contexts". — [llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md), [llama.vim (HF mirror)](https://huggingface.co/datasets/echodict/llama.cpp/blob/main/examples/llama.vim)
- llama.vim sends a zero-generation request whenever its context ring changes, so the server pre-processes the new context ahead of time. — [llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)
- **SWA and hybrid/recurrent pitfall:**
  - Full-attention KV can be truncated to a common prefix. SWA KV and recurrent state cannot, because they are overwritten in place.
  - llama-server stores "context checkpoints" of the non-reconstructible state: `-ctxcp` 32 per slot, `-cms` 8192-token min step, with checkpoints created at user-message boundaries since PR #24176 (2026-06-23).
  - If no checkpoint covers the resume point, the server logs "forcing full prompt re-processing due to lack of cache data".
  - `--checkpoint-every-n-tokens` was removed by PR #22929 (2026-05-25).
  - `--swa-full` gives SWA layers a full-size cache, restoring rollback at a KV memory cost; it is a no-op when `n_swa = 0`.
  - Checkpoints observed at about 60–215 MiB each.
  — [particula.tech (late July 2026 master)](https://particula.tech/blog/prompt-reprocessing-swa-hybrid-models-kv-cache), [llama.cpp issue #24587](https://github.com/ggml-org/llama.cpp/issues/24587)
- Reddit reports blame cache invalidation with Gated DeltaNet models (Qwen3.5) when earlier prompt content is edited. — [r/LocalLLaMA snapshot (May 2026)](https://reddit.sentinel-team.org/posts/1td9stc/snapshots/2026-05-15T23%3A40%3A01.25497Z)

**MLX caching**
- MLX uses a "full prefill strategy" by default. Community add-ons such as oMLX persist KV to SSD, with repeated-prefix TTFT reportedly falling from 30–90 s to 1–3 s on large models (baseline not stated). — [yage.ai](https://yage.ai/share/mlx-apple-silicon-en-20260331.html)
- mlx-lm supports prompt-cache files and a rotating KV cache. — [mlx-lm README](https://github.com/ml-explore/mlx-lm/blob/main/README.md)

**Measured benchmarks (with hardware and date)**
- llama.cpp official Apple Silicon table: Llama-2 7B, pp512 / tg128 tok/s, build 8e672ef (Nov 21, 2023) unless noted. — [llama.cpp discussion #4167](https://github.com/ggml-org/llama.cpp/discussions/4167)

  | Chip (GPU cores, BW) | Q8_0 pp | Q8_0 tg | Q4_0 pp | Q4_0 tg | Build |
  |---|---|---|---|---|---|
  | M1 (8c, 68 GB/s) | 117.3 | 7.9 | 118.0 | 14.2 | 2023 |
  | M2 (10c, 100 GB/s) | 181.4 | 12.2 | 179.6 | 21.9 | 2023 |
  | M3 (10c, 100 GB/s) | 187.5 | 12.3 | 186.8 | 21.3 | 2023 |
  | M4 (10c, 120 GB/s) | 223.6 | 13.5 | 221.3 | 24.1 | 2023 |
  | M4 Pro (20c, 273 GB/s) | 449.6 | 30.7 | 439.8 | 50.7 | 2023 |
  | M4 Max (40c, 546 GB/s) | 891.9 | 54.1 | 885.7 | 83.1 | 2023 |
  | M5 (10c, 154 GB/s) | 715.4 | 18.4 | 722.8 | 31.9 | c1d0e7a (2026; partial row, column alignment inferred) |

  The thread comments also report M5 Max at about 3,200 t/s Q4_0 pp and about 119 t/s tg on a different build.
- Apple MLX, M5 vs M4 MacBook Pro 24 GB (Nov 2025, `mlx_lm.generate`, 4096-token prompt, 128 generated tokens):
  - Qwen3-1.7B BF16: TTFT 3.57x faster, generation 1.27x faster.
  - Qwen3-8B 4-bit: TTFT 3.97x, generation 1.24x.
  - Memory bandwidth: M4 120 GB/s vs M5 153 GB/s.
  - Absolute values appear only in a figure. Secondary sources quote the Qwen3-1.7B TTFT as 3.79 s on M4 vs 1.06 s on M5, but another source gives conflicting numbers (0.33 s vs 0.15 s).
  — [Apple ML Research](https://machinelearning.apple.com/research/exploring-llms-mlx-m5); [kocpc](https://en.kocpc.com.tw/?p=14245) vs [lilting.ch](https://lilting.ch/en/articles/ollama-mlx-apple-silicon-preview) (conflicting)
- Small-model MLX vs llama.cpp: an M4 Max with a 0.6B model reportedly reached 525 tok/s on MLX vs 281 tok/s on llama.cpp. An M2 Ultra with Qwen 7B reached about 230 vs 150 tok/s. Both come from secondary blog aggregation; methodology unverified. — [search aggregation incl. bestllmfor.com](https://bestllmfor.com/guides/mlx-local-llm-apple-silicon/), [towardsai](https://pub.towardsai.net/apples-mlx-runs-local-llms-3x-faster-than-llama-cpp-until-your-context-hits-40k-715ec441afbb)
- Qwen3-0.6B "races above 180 tok/s" in LM Studio on an M4 MacBook Pro (quantization not stated). — [wolfram HF post](https://huggingface.co/posts/wolfram/819510719695955)
- MLX can lag llama.cpp in prefill/TTFT. In an M1 Max anecdote with a ~650-token prompt, effective speed was MLX 13 vs GGUF 20 tok/s, with MLX spending 94% of its time in prefill. — [yage.ai citing r/LocalLLaMA](https://yage.ai/share/mlx-apple-silicon-en-20260331.html)
- Apple Foundation Models: about 20–30 tok/s expected per Apple DevRel. — [Forums 791993](https://developer.apple.com/forums/thread/791993)

**Power, thermal and residency**
- Foundation Models rate-limits on battery for background processes. — [Forums 789788](https://developer.apple.com/forums/thread/789788)
- MLX wires model and cache memory; large models relative to RAM are slow. — [mlx-lm README](https://github.com/ml-explore/mlx-lm/blob/main/README.md)
- Cotypist claims "low battery impact" at about 1–2.5 GB RAM, but publishes no numbers. — [Cotypist press](https://cotypist.app/press)
- Gemma 3 270M INT4 used 0.75% battery for 25 conversations on a Pixel 9 Pro (Google internal test). — [Google Developers Blog](https://developers.googleblog.com/introducing-gemma-3-270m/)

**Speculative decoding**
- llama-server supports draft-model, EAGLE3 and n-gram speculation (`--spec-type`, default `none`; `--spec-draft-n-max` default 3). — [llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- Zed's n-gram speculation works because edit-prediction output copies the input. — [Zed blog](https://zed.dev/blog/edit-prediction)

### Inferences
- **Rough per-keystroke latency for small models:** these are my estimates, scaled from the 7B llama.cpp table, where decode is roughly bandwidth-bound by weight bytes and prefill roughly scales with parameter count. They ignore the fixed per-token overheads that hurt tiny models, so treat them as optimistic. Validate with `llama-bench -p 512 -n 32`.
  - Qwen3-1.7B Q4_K_M (~1.1 GB weights, about 3.5x smaller than 7B Q4_0):
    - Base M1: about 50 tok/s decode, about 450–500 tok/s prefill.
    - Base M4: about 85 tok/s decode, about 900 tok/s prefill.
    - M4 Pro: about 170 tok/s decode.
  - Qwen3-0.6B: about 2–3x faster again. This is consistent with the "180+ tok/s on M4 MacBook Pro" report.
  - **Cold:** a 512-token prompt takes about 1 s for a 1.7B model on base M1 and about 0.5 s on base M4. That is too slow per keystroke, so prefill when focus or text-field changes and reuse the cache.
  - **Warm:** with only 1–10 new tokens per keystroke, prefill is about 10–20 ms. One decode step on base M4 is about 12 ms, so first-token latency is about 30–50 ms and a 10-token suggestion takes about 150 ms. This fits Zed's 200 ms p50 target.
- **Debounce policy for prose** (transferable from llama.vim and Continue):
  - Prefetch at about 0 ms on word boundaries (space/punctuation). Otherwise debounce about 75–150 ms after the last keystroke.
  - Always cancel the in-flight request on a new keystroke. With in-process llama.cpp this is a cancellation flag checked between decode steps.
  - Never queue more than one pending request.
- **KV reuse strategy:**
  - With in-process llama.cpp, keep one sequence and roll the KV back to the longest common prefix with the new prompt (`llama_memory_seq_rm`-style truncation) for full-attention models such as Qwen3.
  - For Qwen3.5 (recurrent) and Gemma 4 (SWA), save a state snapshot at the end of the stable prompt portion (e.g., after the header and retrieved context) and also right before generation, then restore instead of reprocessing. Alternatively use `--swa-full` for SWA models.
  - Append-only typing is cheap for every architecture, as long as you restore the pre-generation state first so the discarded generated tokens are not in the state. Backspace and caret jumps are the expensive cases.
  - llama-server's chat-oriented checkpoint policy (checkpoints at user-message boundaries, 8192-token min step) may cause full reprocessing on every autocomplete request with hybrid models. That favours in-process integration or a full-attention model such as Qwen3 if you use server mode. Verify empirically.
- **Residency:** keep the model loaded, and memory-mapped or wired, for the life of the app. Reload costs seconds. Offer a "pause/unload when on battery below X%" option.
- **Batching:** a single-user autocomplete needs just one sequence/slot. `--parallel 1` avoids splitting context and cache. Batching matters only if you generate several candidates at once; llama.vim defaults `n_cmpl` = 1.
- **Speculative decoding:** probably not worth it for 0.5–2B models generating 10–20 tokens. Draft overhead is comparable to target cost, and prose continuation rarely copies from the prompt, so n-gram lookup has low acceptance.
- **"Speculative prefetch" of the next suggestion** (llama.vim) is worth it (see Q8).
- **Foundation Models** (20–30 tok/s plus background/battery rate limits) cannot meet a 200 ms p50 for multi-word ghost text. It is best kept as an optional engine for users who won't download a model.

### Gaps
- I found no rigorous, dated llama-bench numbers for 0.5–4B models on M1–M4. All small-model figures above are either secondary/anecdotal or my scaled estimates.
- I found no measured MLX vs llama.cpp TTFT comparison at short (200–1000 token) prompts with prefix caching.
- I found no published energy-per-suggestion or battery-drain measurements for continuous ghost-text autocomplete on a Mac.
- I could not confirm mainline llama.cpp's exact behavior for Gemma 4 SWA/shared-KV rollback.

---

## 5. Mid-word completion (user typed "prob" → model continues "ably"): token healing and constrained decoding

### Takeaway
Do not end the prompt on a partial word as-is. Either:
- Apply **token healing**: back off the last token(s) to a clean boundary, then constrain the first generated token(s) so their text starts with the removed characters.
- Or strip the partial word and filter or constrain candidates whose text starts with the typed fragment.

This is implementable in-process with llama.cpp logit masking over a precomputed vocabulary trie. KeyType does this ("logit masking, trie admissibility").

### Cited Findings
- **Token healing** backs up one token from the end of the prompt and constrains the first generated token to start with the removed text. It fixes the bias that appears when a prompt ends mid-token, e.g. a prompt ending in "http:" fails to produce "//". — [Guidance docs: Token healing](https://guidance.readthedocs.io/en/latest/example_notebooks/tutorials/token_healing.html), [Scott Lundberg, "The Art of Prompt Design: Prompt Boundaries and Token Healing" (TDS)](https://towardsdatascience.com/the-art-of-prompt-design-prompt-boundaries-and-token-healing-3b2448b0be38)
- The effect is negligible for tokenizers with clear word boundaries but large for tokenizers that allow whitespace or newlines inside tokens. — [arXiv 2402.01035, "Getting the most out of your tokenizer…"](https://arxiv.org/pdf/2402.01035)
- Guidance supports token healing only with direct backend integration: its LlamaCpp and Transformers backends. — [Guidance docs](https://guidance.readthedocs.io/en/latest/example_notebooks/tutorials/token_healing.html)
- Sweep describes using token healing in autocomplete to fix partial-identifier completions. — [Sweep blog, "Using token healing to teach LLMs to spell"](https://blog.sweep.dev/posts/token-healing-autocomplete)
- KeyType's `ConstrainedGeneration` package does "logit masking, trie admissibility, search", and its `TokenProfiles` read an offline-built "ACPF profile". — [johnbean393/KeyType](https://github.com/johnbean393/KeyType)
- llama-server can return top-N token probabilities (`n_probs`). — [llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

### Inferences
- **Practical algorithm (in-process llama.cpp or MLX):**
  1. Split the text before the caret into a committed prefix (up to the last whitespace or punctuation) and a partial fragment (e.g., "prob").
  2. Tokenize the committed prefix plus the fragment, then remove trailing tokens until the removed text covers the fragment. This is the healing back-off, usually one or two tokens.
  3. For the first decode steps, mask logits to tokens whose decoded text is consistent with the remaining required characters: either it is a prefix of the remainder, or the remainder is a prefix of it. A trie or sorted vocabulary table built once per tokenizer makes this fast.
  4. Once the fragment is covered, decode freely, and display only the characters beyond what the user typed ("ably …").
  5. Optionally run a short beam or top-k search over the constrained first token (KeyType's "search") so a low-probability first piece doesn't derail the suggestion.
- A cheaper fallback that works with any HTTP backend: send the prompt without the fragment, request `n_probs` or several samples, and keep only completions whose text starts with the fragment. This wastes compute and often finds nothing, so prefer true constrained decoding in-process.
- Because SentencePiece/BPE tokenizers in Qwen and Gemma attach leading spaces to word tokens, prose has a clear word-boundary structure. Healing just the partial word (not whitespace) therefore covers most cases.
- **Client-side reuse:** if the user types characters that match the visible suggestion, no new inference is needed; just shift the ghost text (llama.vim's typed-prefix cache match).

### Gaps
- I found no published measurement of token-healing impact on prose-completion acceptance specifically.
- I found no built-in token-healing flag in mainline llama-server; it must be implemented client-side or in-process. Not verified exhaustively.

---

## 6. Personalization (on-device LoRA on the user's own writing, retrieval of past writing as few-shot context, privacy)

### Takeaway
Start with **retrieval/in-context personalization**: keep an encrypted local store of the user's own accepted or typed text per app and recipient, and inject 1–3 relevant snippets plus a short style profile into the stable prompt header. Optional on-device LoRA (mlx-lm or mlx-swift-lm) is feasible on Apple Silicon for ≤2B models and can further match voice. Apple's Foundation Models adapters are impractical: they need an entitlement, are tied to a single model version, need a 32 GB+ Mac to train, and the toolkit is discontinued for OS 27.

### Cited Findings
- Cotypist learns "vocabulary, names, and phrasing across apps", with personalization data encrypted on the Mac and no telemetry on typed text. — [Cotypist press](https://cotypist.app/press)
- Cotabby conditions on the user's name, writing style and language. — [FuJacob/cotabby](https://github.com/FuJacob/cotabby)
- mlx-lm supports LoRA and full fine-tuning, including on quantized models (QLoRA-style); see `mlx_lm/LORA.md`. — [mlx-lm README](https://github.com/ml-explore/mlx-lm/blob/main/README.md)
- `mlx_lm.lora` reports training/validation loss, tokens processed and iterations/sec. LoRA on a 7B 4-bit model needs about 7 GB, and examples use `--batch-size 1` to fit 16 GB machines. — [insiderllm guide](https://insiderllm.com/guides/fine-tuning-mac-lora-mlx/), [DZone mlx-lm guide](https://dzone.com/articles/fine-tuning-llms-locally-using-mlx-lm-guide) (secondary)
- mlx-swift-lm lists LoRA/DoRA fine-tuning among its Swift features, so training could happen inside a Swift app. — [skills.sh mlx-swift-lm](https://www.skills.sh/ml-explore/mlx-swift-lm/swift-mlx-lm)
- Apple Foundation Models adapters:
  - About 160 MB each.
  - Deploying them requires the adapter entitlement.
  - Each works with only one system-model version.
  - Training needs a 32 GB+ Apple Silicon Mac or a Linux GPU.
  - Toolkit 26.0.0 is the last release and is incompatible with OS 27.
  — [Apple adapter page](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)
- llama.vim's "ring buffer" retrieval pattern:
  - Chunks are gathered from yanks, buffer enter/leave and saves.
  - Near-duplicates (similarity > 0.9) are evicted.
  - Chunks are promoted into an active set (`ring_n_chunks` 16, FIFO eviction) every `ring_update_ms` = 1000, followed by a zero-generation request to pre-process them.
  - Before each request, chunks too similar (> 0.5) to the current window are pruned.
  — [llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)

### Inferences
- **Retrieval design for prose** (adapted from llama.vim):
  - Store snippets of what the user wrote in each app and conversation: accepted completions, plus sent text if captured with consent.
  - Index them locally with a small embedding model, or with simple BM25/keyword matching to stay lightweight.
  - Prepend the top 1–3 snippets as "previous messages by {Name}".
  - Change the retrieved block only on focus or field change, not per keystroke, to preserve KV reuse. Prefill it with an `n_predict=0` request.
- **LoRA:** a rank-8–16 LoRA on a 0.8–2B base model trained on a few MB of the user's text should fit comfortably on a 16 GB Mac. The adapter would be a few MB to tens of MB.
  - Overnight or on-charger training avoids thermal and battery impact.
  - With llama.cpp, the adapter would need converting to GGUF LoRA format and loading at runtime. With MLX it can be used directly.
  - Retraining is required whenever the base model changes.
- **Privacy:**
  - Keep all text local and encrypted (Keychain-protected key).
  - Exclude secure/password fields, and let users exclude apps (banking, password managers).
  - Never send personalization data to BYO cloud endpoints unless the user explicitly opts in.
  - Note that a LoRA trained on private text memorizes it, so treat the adapter file as sensitive.

### Gaps
- I found no measured LoRA training throughput for 0.5–2B models on base M1/M2/M3, and no published evaluation of LoRA vs retrieval for personal writing-style autocomplete.
- I did not verify llama.cpp's current GGUF-LoRA conversion path for Qwen3.5/Gemma 4 this session.

---

## 7. Optional cloud / BYO-API mode (OpenAI-compatible endpoints, Ollama / LM Studio local servers)

### Takeaway
Offer a pluggable backend interface:
- In-process llama.cpp (default).
- Apple Foundation Models (zero-download fallback; on macOS 27, any Language-Model-protocol provider).
- Generic OpenAI-compatible HTTP (Ollama, LM Studio, llama-server, or cloud APIs) with the key in Keychain.

Prefer raw completion endpoints (llama-server `/completion`) over chat endpoints, because chat templates turn continuation into "answering".

### Cited Findings
- Cotabby's OpenAI-compatible engine sends a bounded request only to the endpoint the user configures and stores credentials in Keychain. — [FuJacob/cotabby](https://github.com/FuJacob/cotabby)
- GhostType connects to external OpenAI-compatible servers, including llama.cpp, LM Studio and Ollama. — [GhostType mirror](https://ithub.global.ssl.fastly.net/mk668a/GhostType)
- llama-server's `/completion` takes a raw prompt with `n_predict`, `stop`, `cache_prompt` and so on; `/infill` takes FIM fields. — [llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- Ollama's wrapper overhead was roughly half the throughput of raw llama.cpp on M4 Max (43.5 vs 89.4 tok/s). Ollama 0.19 moved to an MLX backend on Apple Silicon. — [yage.ai](https://yage.ai/share/mlx-apple-silicon-en-20260331.html)
- macOS 27's Foundation Models framework accepts any provider conforming to the Language Model protocol (Apple, Claude, Gemini, others). Small Business Program apps with fewer than 2M first-time downloads get the next-gen Apple model on Private Cloud Compute at no API cost. — [Apple What's new in macOS 27](https://developer.apple.com/macos/whats-new/)

### Inferences
- **Cloud latency:** network round-trips (typically 100–500 ms plus queueing) make cloud backends feel slower than a warm local 1–2B model for ghost text. They are better suited to longer "complete this paragraph" requests triggered on demand.
- **Privacy:** cloud mode sends what the user is typing in every app to a third party. It should be off by default, clearly labelled, have per-app allow-lists, and be disabled in secure fields.
- **Chat-only APIs:** emulate continuation with a system prompt such as "Continue the user's text verbatim; output only the continuation", plus the text as a user message. Expect lower faithfulness than with a base model.
- The macOS 27 Language Model protocol could become the cleanest abstraction for an app targeting macOS 27+, with one API for Apple on-device, PCC and third-party providers. Most users will still be on older macOS versions in 2026, so a custom backend protocol remains necessary.

### Gaps
- I did not verify the exact OpenAI-compatible routes (`/v1/completions` vs `/v1/chat/completions`) exposed by current llama-server, Ollama and LM Studio builds this session.
- I found no latency measurements for cloud autocomplete backends.

---

## 8. Techniques from code-autocomplete tools (llama.vim/llama.vscode, Continue, Tabby, Zed, Copilot) transferable to prose

### Takeaway
llama.vim/llama.vscode (by ggml-org, the llama.cpp authors) is the most directly transferable open design. Its key techniques:
- A local hashed suggestion cache, including reuse when typed characters match a cached suggestion.
- Speculative prefetch of the next suggestion as if the current one were accepted.
- A background "ring buffer" of extra context, pre-processed with zero-generation requests.
- Server-side `cache_prompt` and `--cache-reuse`.
- 100 ms debounce with cancellation, a fast first-request time cap, and output filtering.

Continue adds position-based cache reuse (e.g., after backspace), and Zed contributes explicit latency targets.

### Cited Findings
- llama.vim local cache:
  - Responses are keyed by SHA-256 of prefix + middle + suffix, plus extra keys that drop leading prefix lines so suggestions survive small scrolls.
  - LRU eviction with `max_cache_keys` = 250.
  - Typed-prefix reuse: for up to 128 trailing typed characters, it looks up the context before those characters, and if a cached completion starts with what was typed, shows the remainder with no new request.
  — [llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)
- llama.vim speculative prefetch: after showing a suggestion, it immediately requests the next completion with the context built "as if the suggestion were already inserted" and caches it, so acceptance yields an instant follow-up. — [llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)
- llama.vim filtering: it discards empty or whitespace-only suggestions and ones that repeat the existing line, suffix or following lines. Accept keymaps cover full, line and word. — [llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)
- llama.vim request: `/infill` with `cache_prompt: true`, `samplers: ["top_k","top_p","infill"]`, `top_k` 40, `top_p` 0.90, and `response_fields` including `timings/*` and `tokens_cached` for monitoring. — [llama.vim source](https://raw.githubusercontent.com/ggml-org/llama.vim/master/autoload/llama.vim)
- llama.vscode rings in context chunks from open/edited files and yanked text and requires a FIM-capable model on llama-server. — [llama.vscode (fork mirror)](https://github.com/emcodem/llama.vscode)
- The llama.vim screenshot shows "30 chunks in ring buffer (out of 64)". The sample server flags include `--cache-reuse 256`. — [llama.vim HF mirror](https://huggingface.co/datasets/echodict/llama.cpp/blob/main/examples/llama.vim)
- Continue: debounce (waits for typing to stop), reuse of an existing completion at a previously completed cursor position (e.g., after backspace), retrieval of codebase snippets, and post-processing that removes special tokens, stops early, fixes indentation and discards repetitive output. — [Continue docs](https://docs.continue.dev/ide-extensions/autocomplete/how-it-works)
- Zed Zeta: under 200 ms p50 and under 500 ms p90 targets, n-gram speculative decoding, and a 7B fine-tune (Qwen2.5-Coder-7B) served remotely. — [Zed blog](https://zed.dev/blog/edit-prediction), [Zeta model readme](https://featherless.ai/models/zed-industries/zeta/readme)

### Inferences
- **Direct transfers to prose:**
  1. **Typed-prefix cache:** when the user types the next characters of the ghost text, just advance the ghost text. This is the single biggest perceived-latency win and costs zero inference.
  2. **Speculative prefetch on accept:** when a suggestion is shown, precompute the continuation after it, so Tab followed by more suggestions feels instant.
  3. **Zero-generation prefill** (`n_predict: 0`) on focus change, field change or retrieval-context change.
  4. **Ring-buffer equivalent:** recent text from the same app or conversation, and other open windows, deduplicated and pruned when too similar to the visible text.
  5. **Backspace or position revisit:** reuse cached suggestions keyed by a hash of the context.
  6. **Filtering:** drop suggestions that repeat the existing sentence, duplicate text after the caret, or are whitespace or punctuation only.
  7. **Accept granularity:** full, word or sentence.
- **Differences from code:**
  - Prose has no indentation or syntax signals for stopping, so use sentence-boundary stops.
  - Prose FIM is rarely available, so gate on caret position instead.
  - The "files" analog is per-app or per-recipient history, which has privacy implications (Q6).

### Gaps
- I found no published details of Copilot's or Tabby's current debounce intervals or client cache design.
- Continue's default debounce value and cache key design were not on the fetched docs page (they are in its "deep dive" or source, not fetched).
