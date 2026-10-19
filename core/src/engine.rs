//! In-process llama.cpp inference tuned for keystroke-rate completion.
//!
//! - One sequence, one context. Every request is reconciled against the tokens already in
//!   the KV cache: the longest common prefix is kept and only the new tail is prefilled.
//!   Generated tokens are rolled back afterwards, so the cache always mirrors the prompt.
//! - Token healing: the prompt stops before the partial word, and the first decode steps
//!   are masked to tokens consistent with what the user already typed. The committed prefix
//!   therefore stays identical for a whole word, and mid-word completion works even when
//!   the typed fragment is not a token boundary.
//! - Greedy decoding with word, sentence, newline and wall-clock limits, cancellable between
//!   decode steps.
//! - Optional personal-vocabulary bias: logit boosts towards words the user often writes,
//!   both for whole single-token words at a word start and for completing a word in
//!   progress (typed or generated) into one of the user's words.
//!
//! Rolling the cache back depends on the architecture:
//! - Dense full-attention models (Qwen3) and sliding-window models (Gemma 4, with a
//!   full-size SWA cache so no cell is overwritten) drop the KV cells past the position.
//! - Recurrent and hybrid models (Qwen3.5) keep a running state that can't be cut back, so
//!   the engine snapshots the recurrent state just before the last prompt token of each
//!   prompt, restores the nearest matching snapshot and drops the attention cells after it.

use std::collections::{HashMap, VecDeque};
use std::mem::ManuallyDrop;
use std::num::NonZeroU32;
use std::time::{Duration, Instant};

use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::context::session::{LlamaStateSeqFlags, SeqState};
use llama_cpp_2::context::LlamaContext;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::token::LlamaToken;

use crate::context::Prompt;
use crate::words;

#[derive(Debug, Clone)]
pub struct EngineConfig {
    pub model_path: String,
    pub n_ctx: u32,
    pub n_batch: u32,
    pub n_gpu_layers: u32,
    pub n_threads: i32,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self { model_path: String::new(), n_ctx: 2048, n_batch: 512, n_gpu_layers: 999, n_threads: 4 }
    }
}

#[derive(Debug, Clone)]
pub struct GenOptions {
    pub max_words: usize,
    pub deadline: Duration,
    pub stop_at_sentence_end: bool,
    /// Logit boost for the user's own words at full weight (0 = off).
    pub personal_strength: f32,
}

impl Default for GenOptions {
    fn default() -> Self {
        Self { max_words: 4, deadline: Duration::from_millis(300), stop_at_sentence_end: true, personal_strength: 0.0 }
    }
}

/// The user's vocabulary prepared for biasing.
#[derive(Default)]
struct Vocabulary {
    /// (display form, lowercase form, weight in (0, 1]), heaviest first.
    words: Vec<(String, String, f32)>,
    /// Token of " word" for words that are a single token, with weight.
    whole: HashMap<i32, f32>,
}

/// How the engine takes the cache back to an earlier position.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rollback {
    /// Remove the KV cells after the position (dense and sliding-window attention).
    Truncate,
    /// Restore a recurrent-state snapshot, then remove the attention cells after it
    /// (recurrent and hybrid models).
    Snapshot,
}

/// Snapshots kept per engine. Each holds the recurrent state for one prompt (minus its last
/// token); typing usually needs the newest one, a backspace across a word an older one.
const MAX_SNAPSHOTS: usize = 4;

/// Recurrent state after exactly `tokens` had been decoded.
struct StateSnapshot {
    tokens: Vec<LlamaToken>,
    state: SeqState,
}

#[derive(Debug)]
pub enum GenError {
    Cancelled,
    Failed(String),
}

#[derive(Debug, Clone, Default)]
pub struct Completion {
    /// Text to show after the caret (fragment already removed).
    pub text: String,
    pub prompt_tokens: usize,
    pub prefilled_tokens: usize,
    pub generated_tokens: usize,
    pub prefill_ms: f64,
    pub total_ms: f64,
    pub stop: &'static str,
}

pub struct Engine {
    backend: *mut LlamaBackend,
    model: *mut LlamaModel,
    /// Borrows `*model`; dropped by hand before the model is freed.
    ctx: ManuallyDrop<LlamaContext<'static>>,
    batch: LlamaBatch<'static>,
    /// Tokens currently held in the KV cache for sequence 0.
    cached: Vec<LlamaToken>,
    /// Detokenized bytes of every vocabulary entry (empty for control tokens).
    pieces: Vec<Vec<u8>>,
    eog: Vec<bool>,
    add_bos: bool,
    n_batch: usize,
    n_ctx: usize,
    vocab_bias: Vocabulary,
    rollback: Rollback,
    snapshots: VecDeque<StateSnapshot>,
}

fn ms(since: Instant) -> f64 {
    since.elapsed().as_secs_f64() * 1000.0
}

impl Engine {
    /// Loads the model. The backend and model live on the heap behind raw pointers so the
    /// context can borrow the model for `'static`; `Drop` frees all three in order (Metal
    /// asserts at process exit if the context outlives its device).
    pub fn load(cfg: &EngineConfig) -> Result<Self, String> {
        if !std::path::Path::new(&cfg.model_path).is_file() {
            return Err(format!("model file not found: {}", cfg.model_path));
        }
        let mut backend = LlamaBackend::init().map_err(|e| format!("backend init: {e}"))?;
        if std::env::var_os("FORETYPE_LLAMA_LOGS").is_none() {
            backend.void_logs();
        }
        let backend_ptr = Box::into_raw(Box::new(backend));
        // SAFETY: freed only in Drop, after everything that borrows it.
        let backend: &'static LlamaBackend = unsafe { &*backend_ptr };
        let mparams = LlamaModelParams::default().with_n_gpu_layers(cfg.n_gpu_layers);
        let free_backend = || drop(unsafe { Box::from_raw(backend_ptr) });
        let model = match LlamaModel::load_from_file(backend, &cfg.model_path, &mparams) {
            Ok(m) => m,
            Err(e) => {
                free_backend();
                return Err(format!("model load: {e}"));
            }
        };
        let rollback = if model.is_recurrent() || model.is_hybrid() { Rollback::Snapshot } else { Rollback::Truncate };
        let model_ptr = Box::into_raw(Box::new(model));
        // SAFETY: freed only in Drop, after the context that borrows it.
        let model: &'static LlamaModel = unsafe { &*model_ptr };
        let cparams = LlamaContextParams::default()
            .with_n_ctx(NonZeroU32::new(cfg.n_ctx))
            .with_n_batch(cfg.n_batch)
            .with_n_ubatch(cfg.n_batch)
            .with_n_seq_max(1)
            // Sliding-window layers normally overwrite cells that left the window, which
            // makes rolling back impossible; at a 2,048-token context the full-size cache
            // costs little.
            .with_swa_full(true)
            .with_n_threads(cfg.n_threads)
            .with_n_threads_batch(cfg.n_threads);
        let ctx = match model.new_context(backend, cparams) {
            Ok(c) => c,
            Err(e) => {
                drop(unsafe { Box::from_raw(model_ptr) });
                free_backend();
                return Err(format!("context: {e}"));
            }
        };

        let vocab = model.vocab();
        let n_vocab = vocab.n_tokens().max(0) as usize;
        let mut pieces = Vec::with_capacity(n_vocab);
        let mut eog = Vec::with_capacity(n_vocab);
        for id in 0..n_vocab as i32 {
            let t = LlamaToken(id);
            let control = vocab.is_control(t);
            eog.push(vocab.is_eog(t));
            pieces.push(if control { Vec::new() } else { vocab.token_to_piece(t, false, None) });
        }
        let add_bos = vocab.should_add_bos();
        Ok(Self {
            backend: backend_ptr,
            model: model_ptr,
            ctx: ManuallyDrop::new(ctx),
            batch: LlamaBatch::new(cfg.n_batch as usize, 1),
            cached: Vec::new(),
            pieces,
            eog,
            add_bos,
            n_batch: cfg.n_batch as usize,
            n_ctx: cfg.n_ctx as usize,
            vocab_bias: Vocabulary::default(),
            rollback,
            snapshots: VecDeque::new(),
        })
    }

    fn model(&self) -> &LlamaModel {
        // SAFETY: valid until Drop.
        unsafe { &*self.model }
    }

    pub fn rollback(&self) -> Rollback {
        self.rollback
    }

    /// Bytes held by recurrent-state snapshots (0 for truncating models).
    pub fn snapshot_bytes(&self) -> usize {
        self.snapshots.iter().map(|s| s.state.byte_len()).sum()
    }

    /// Empties the cache and drops all snapshots (the next request prefills from scratch).
    pub fn reset(&mut self) {
        self.ctx.clear_kv_cache();
        self.cached.clear();
        self.snapshots.clear();
    }

    pub fn tokenize(&self, text: &str) -> Vec<LlamaToken> {
        self.model().vocab().tokenize(text.as_bytes(), self.add_bos, false)
    }

    /// Tokenizes a fragment in the middle of a text (no BOS).
    fn tokenize_piece(&self, text: &str) -> Vec<LlamaToken> {
        self.model().vocab().tokenize(text.as_bytes(), false, false)
    }

    /// Installs the user's vocabulary (word, weight in (0, 1]) for personal biasing.
    pub fn set_vocabulary(&mut self, words: &[(String, f32)]) {
        let mut whole = HashMap::new();
        for (w, weight) in words {
            let toks = self.tokenize_piece(&format!(" {w}"));
            if toks.len() == 1 {
                let e = whole.entry(toks[0].0).or_insert(0.0f32);
                *e = e.max(*weight);
            }
        }
        self.vocab_bias = Vocabulary {
            words: words.iter().map(|(w, s)| (w.clone(), w.to_lowercase(), *s)).collect(),
            whole,
        };
    }

    /// Logit boosts for the next token given the text produced so far (`full`: what the
    /// user typed of the current word, or what was generated, whichever is longer) and the
    /// bytes already generated (`out_len`).
    fn step_bias(&self, full: &str, out_len: usize, strength: f32) -> Vec<(usize, f32)> {
        if strength <= 0.0 || self.vocab_bias.words.is_empty() {
            return Vec::new();
        }
        let partial_start = full
            .char_indices()
            .rev()
            .take_while(|(_, c)| c.is_alphanumeric() || *c == '\'' || *c == '\u{2019}')
            .last()
            .map_or(full.len(), |(i, _)| i);
        let partial = &full[partial_start..];
        if partial.is_empty() {
            // Word start: only whole-word tokens, so common sub-word prefixes stay neutral.
            if out_len > 0 && !full.ends_with(char::is_whitespace) {
                return Vec::new();
            }
            return self.vocab_bias.whole.iter().map(|(&t, &w)| (t as usize, w * strength)).collect();
        }
        // Completing a word: steer towards the user's words that extend `partial`.
        let lower = partial.to_lowercase();
        let mut out = Vec::new();
        for (display, low, w) in self.vocab_bias.words.iter() {
            if low.len() <= lower.len() || !low.starts_with(&lower) {
                continue;
            }
            let typed_chars = partial.chars().count();
            let rest: String = display.chars().skip(typed_chars).collect();
            let desired = format!("{}{}", full, rest);
            if desired.len() <= out_len {
                continue;
            }
            if let Some(t) = self.tokenize_piece(&desired[out_len..]).first() {
                out.push((t.0 as usize, w * strength));
            }
            if out.len() >= 8 {
                break;
            }
        }
        out
    }

    /// Makes the KV cache hold exactly `tokens` and leaves the logits of the last token in
    /// batch slot `0` of the last decode. Returns how many tokens were prefilled.
    fn sync(&mut self, tokens: &[LlamaToken], cancel: &dyn Fn() -> bool) -> Result<usize, GenError> {
        if tokens.is_empty() {
            return Err(GenError::Failed("empty prompt".into()));
        }
        if tokens.len() + 64 > self.n_ctx {
            return Err(GenError::Failed(format!("prompt of {} tokens exceeds context", tokens.len())));
        }
        let common = self.cached.iter().zip(tokens).take_while(|(a, b)| a == b).count();
        // The last prompt token must be decoded again: its logits were overwritten by
        // whatever was generated after it last time.
        let keep = common.min(tokens.len() - 1);
        if keep < self.cached.len() {
            self.rewind(&tokens[..keep])?;
        }
        let start = self.cached.len();
        let last = tokens.len() - 1;
        if self.rollback == Rollback::Snapshot {
            // Snapshot the state before the last token: the next keystroke in the same word
            // sends the same prompt, and generation is undone by returning here.
            self.decode(tokens, start, last, cancel)?;
            self.snapshot();
            self.decode(tokens, last, tokens.len(), cancel)?;
        } else {
            self.decode(tokens, start, tokens.len(), cancel)?;
        }
        Ok(tokens.len() - start)
    }

    /// Decodes `tokens[from..to]` (already cached up to `from`), requesting logits only
    /// for the prompt's final token.
    fn decode(&mut self, tokens: &[LlamaToken], from: usize, to: usize, cancel: &dyn Fn() -> bool) -> Result<(), GenError> {
        for (ci, chunk) in tokens[from..to].chunks(self.n_batch).enumerate() {
            if ci > 0 && cancel() {
                return Err(GenError::Cancelled);
            }
            self.batch.clear();
            let base = from + ci * self.n_batch;
            for (i, &t) in chunk.iter().enumerate() {
                let is_last = base + i == tokens.len() - 1;
                self.batch
                    .add(t, (base + i) as i32, &[0], is_last)
                    .map_err(|e| GenError::Failed(format!("batch: {e}")))?;
            }
            self.ctx.decode(&mut self.batch).map_err(|e| GenError::Failed(format!("decode: {e}")))?;
            self.cached.extend_from_slice(chunk);
        }
        Ok(())
    }

    /// Takes the cache back so it holds a prefix of `target` (all of it when possible).
    fn rewind(&mut self, target: &[LlamaToken]) -> Result<(), GenError> {
        let n = target.len();
        match self.rollback {
            Rollback::Truncate => {
                let ok = self
                    .ctx
                    .clear_kv_cache_seq(Some(0), Some(n as u32), None)
                    .map_err(|e| GenError::Failed(format!("kv rollback: {e}")))?;
                if ok {
                    self.cached.truncate(n);
                    return Ok(());
                }
            }
            Rollback::Snapshot => {
                let best = self
                    .snapshots
                    .iter()
                    .enumerate()
                    .filter(|(_, s)| s.tokens.len() <= n && target.starts_with(&s.tokens))
                    .max_by_key(|(_, s)| s.tokens.len())
                    .map(|(i, _)| i);
                if let Some(i) = best {
                    let snap = self.snapshots.remove(i).expect("index from iter");
                    let len = snap.tokens.len();
                    // Restore the recurrent part first: removing cells from the recurrent
                    // cache at an earlier position fails and would leave it untouched.
                    let restored = self.ctx.state_seq_set(&snap.state, 0).is_ok()
                        && self.ctx.clear_kv_cache_seq(Some(0), Some(len as u32), None).unwrap_or(false);
                    self.snapshots.push_back(snap);
                    if restored {
                        self.cached.truncate(len);
                        return Ok(());
                    }
                }
            }
        }
        // No way back to a shared prefix: start over.
        self.ctx.clear_kv_cache();
        self.cached.clear();
        Ok(())
    }

    /// Records the recurrent state for the tokens now in the cache (once per prompt).
    fn snapshot(&mut self) {
        if let Some(i) = self.snapshots.iter().position(|s| s.tokens == self.cached) {
            let s = self.snapshots.remove(i).expect("index from iter");
            self.snapshots.push_back(s);
            return;
        }
        match self.ctx.state_seq_get(0, LlamaStateSeqFlags::PARTIAL_ONLY) {
            Ok(state) => {
                if self.snapshots.len() >= MAX_SNAPSHOTS {
                    self.snapshots.pop_front();
                }
                self.snapshots.push_back(StateSnapshot { tokens: self.cached.clone(), state });
            }
            Err(e) => eprintln!("[foretype] state snapshot failed: {e}"),
        }
    }

    /// Zero-token request: prefills `prefix` so the next completion only pays for its tail.
    pub fn warm(&mut self, prefix: &str, cancel: &dyn Fn() -> bool) -> Result<usize, GenError> {
        let tokens = self.tokenize(prefix);
        self.sync(&tokens, cancel)
    }

    /// Index (within the last decode batch) holding the logits to sample from next.
    fn logits_index(&self) -> i32 {
        self.batch.n_tokens() - 1
    }

    fn allowed(&self, id: usize, remaining: &[u8]) -> bool {
        let piece = &self.pieces[id];
        if !remaining.is_empty() {
            // Healing: the token must agree with the typed fragment as far as both go.
            !piece.is_empty() && (piece.starts_with(remaining) || remaining.starts_with(piece))
        } else {
            !piece.is_empty() || self.eog[id]
        }
    }

    /// Greedy pick under the healing constraint. Boosts are non-negative and sparse, so the
    /// winner is either the unboosted argmax or one of the boosted tokens.
    fn argmax(&self, logits: &[f32], remaining: &[u8], bias: &[(usize, f32)]) -> Option<LlamaToken> {
        let mut best: Option<(usize, f32)> = None;
        for (id, &l) in logits.iter().enumerate() {
            if best.is_some_and(|(_, b)| l <= b) || !self.allowed(id, remaining) {
                continue;
            }
            best = Some((id, l));
        }
        if !bias.is_empty() {
            let boost = |id: usize| bias.iter().filter(|(t, _)| *t == id).map(|(_, b)| *b).fold(0.0f32, f32::max);
            if let Some((id, l)) = best {
                best = Some((id, l + boost(id)));
            }
            for &(id, _) in bias {
                if id >= logits.len() || !self.allowed(id, remaining) {
                    continue;
                }
                let v = logits[id] + boost(id);
                if best.is_none_or(|(_, b)| v > b) {
                    best = Some((id, v));
                }
            }
        }
        best.map(|(id, _)| LlamaToken(id as i32))
    }

    pub fn complete(
        &mut self,
        prompt: &Prompt,
        opts: &GenOptions,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Completion, GenError> {
        let t0 = Instant::now();
        let tokens = self.tokenize(&prompt.prefix);
        let prefilled = self.sync(&tokens, cancel)?;
        let prefill_ms = ms(t0);
        // The wall-clock cap applies to generation: a cold prefill (first keystroke in a
        // new field) must not eat the whole budget and yield nothing.
        let t_gen = Instant::now();

        let fragment = prompt.fragment.as_bytes();
        let mut out: Vec<u8> = Vec::new();
        let mut generated = 0usize;
        let mut pos = tokens.len();
        let max_tokens = opts.max_words * 3 + 8 + fragment.len();
        let mut stop = "maxTokens";
        let mut idx = self.logits_index();

        let result = loop {
            if generated >= max_tokens {
                break Ok(());
            }
            if cancel() {
                break Err(GenError::Cancelled);
            }
            if t_gen.elapsed() > opts.deadline {
                stop = "deadline";
                break Ok(());
            }
            let remaining: &[u8] = if out.len() < fragment.len() { &fragment[out.len()..] } else { &[] };
            let bias = if opts.personal_strength > 0.0 {
                let full = if out.len() < fragment.len() { &prompt.fragment } else { std::str::from_utf8(&out).unwrap_or("") };
                self.step_bias(full, out.len(), opts.personal_strength)
            } else {
                Vec::new()
            };
            let Some(tok) = self.argmax(self.ctx.get_logits_ith(idx), remaining, &bias) else {
                stop = "noCandidate";
                break Ok(());
            };
            let id = tok.0 as usize;
            if self.eog[id] {
                stop = "eog";
                break Ok(());
            }
            let piece = &self.pieces[id];
            let healed = out.len() >= fragment.len();
            if healed {
                let shown = &out[fragment.len()..];
                if let Some(nl) = piece.iter().position(|&b| b == b'\n') {
                    out.extend_from_slice(&piece[..nl]);
                    stop = "newline";
                    break Ok(());
                }
                // Starting a new word past the limit ends the suggestion.
                let starts_word = piece.first().is_some_and(|b| b.is_ascii_whitespace());
                let shown_str = String::from_utf8_lossy(shown);
                if starts_word && words::count_words(&shown_str) >= opts.max_words {
                    stop = "words";
                    break Ok(());
                }
                if starts_word && opts.stop_at_sentence_end && words::ends_sentence(&shown_str) {
                    stop = "sentence";
                    break Ok(());
                }
            }
            out.extend_from_slice(piece);
            generated += 1;

            self.batch.clear();
            if let Err(e) = self.batch.add(tok, pos as i32, &[0], true) {
                break Err(GenError::Failed(format!("batch: {e}")));
            }
            if let Err(e) = self.ctx.decode(&mut self.batch) {
                break Err(GenError::Failed(format!("decode: {e}")));
            }
            pos += 1;
            idx = 0;
        };

        // Roll the generated tokens back out of the cache so it mirrors the prompt again
        // (with snapshots: the prompt minus its last token, which the next request decodes).
        if pos > tokens.len() {
            let target = match self.rollback {
                Rollback::Truncate => &tokens[..],
                Rollback::Snapshot => &tokens[..tokens.len() - 1],
            };
            self.rewind(target)?;
        }
        result?;

        let mut text = String::new();
        if out.len() >= fragment.len() {
            let shown = &out[fragment.len()..];
            let valid = match std::str::from_utf8(shown) {
                Ok(s) => s,
                Err(e) => std::str::from_utf8(&shown[..e.valid_up_to()]).unwrap_or(""),
            };
            let trimmed = if stop == "maxTokens" || stop == "deadline" {
                words::drop_partial_last_word(valid)
            } else {
                valid
            };
            text = trimmed.trim_end_matches([' ', '\t']).to_string();
        }
        Ok(Completion {
            text,
            prompt_tokens: tokens.len(),
            prefilled_tokens: prefilled,
            generated_tokens: generated,
            prefill_ms,
            total_ms: ms(t0),
            stop,
        })
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // SAFETY: context first (it borrows the model), then model, then backend; none of
        // them is used again.
        unsafe {
            ManuallyDrop::drop(&mut self.ctx);
            drop(Box::from_raw(self.model));
            drop(Box::from_raw(self.backend));
        }
    }
}
