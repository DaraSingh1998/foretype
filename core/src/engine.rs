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
use std::sync::{Condvar, Mutex};
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
    /// Phrases searched at once (1 = greedy). Truncating models only; others stay greedy.
    pub beam_width: usize,
}

impl Default for GenOptions {
    fn default() -> Self {
        Self {
            max_words: 4,
            deadline: Duration::from_millis(300),
            stop_at_sentence_end: true,
            personal_strength: 0.0,
            beam_width: 1,
        }
    }
}

/// Most beams a context is set up for: beams live in sequences 1..=2*MAX_BEAMS (two banks,
/// swapped every step), sequence 0 holds the prompt.
pub const MAX_BEAMS: usize = 8;

/// One phrase being searched.
struct Beam {
    /// Generated tokens; the last one is not in the KV cache yet.
    tokens: Vec<LlamaToken>,
    out: Vec<u8>,
    /// Sum of log-probabilities.
    score: f32,
    seq: i32,
}

/// Average log-probability per token: compares phrases of different lengths fairly.
fn mean_score(score: f32, n: usize) -> f32 {
    score / n.max(1) as f32
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
    /// The prompt (this many tokens) leaves less than 64 tokens of the context free.
    TooLong(usize),
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

/// llama.cpp's backend, one per process. llama-cpp-2 refuses a second `LlamaBackend::init`
/// while one is alive, and the shell starts a new engine (another model, a server, a larger
/// context for other apps' text) before the old one has been freed. It is never freed:
/// `llama_backend_free` only releases quantization tables, and every engine frees its own
/// context and model in `Drop`, so nothing outlives the Metal device at exit.
pub fn backend() -> Result<&'static LlamaBackend, String> {
    static BACKEND: Mutex<Option<&'static LlamaBackend>> = Mutex::new(None);
    let mut slot = BACKEND.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(b) = *slot {
        return Ok(b);
    }
    let mut b = LlamaBackend::init().map_err(|e| format!("backend init: {e}"))?;
    if std::env::var_os("FORETYPE_LLAMA_LOGS").is_none() {
        b.void_logs();
    }
    let b: &'static LlamaBackend = Box::leak(Box::new(b));
    *slot = Some(b);
    Ok(b)
}

/// Engines alive in this process. A new engine waits (up to `REPLACE_WAIT`) for the one it
/// replaces to be freed, so two models aren't in memory at once while the shell swaps them.
static LIVE: (Mutex<usize>, Condvar) = (Mutex::new(0), Condvar::new());
const REPLACE_WAIT: Duration = Duration::from_secs(10);

/// One engine's place in `LIVE`, given back when the engine is dropped (after its context
/// and model) or its load fails.
struct LiveSlot;

impl LiveSlot {
    fn acquire() -> Self {
        let (count, freed) = &LIVE;
        let mut n = count.lock().unwrap_or_else(|e| e.into_inner());
        let deadline = Instant::now() + REPLACE_WAIT;
        while *n > 0 {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            n = freed.wait_timeout(n, left).unwrap_or_else(|e| e.into_inner()).0;
        }
        *n += 1;
        LiveSlot
    }
}

impl Drop for LiveSlot {
    fn drop(&mut self) {
        let (count, freed) = &LIVE;
        let mut n = count.lock().unwrap_or_else(|e| e.into_inner());
        *n = n.saturating_sub(1);
        freed.notify_all();
    }
}

pub struct Engine {
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
    /// The context has room for beam-search sequences (truncating models only).
    beams: bool,
    /// Dropped last, after `Drop` has freed the context and the model.
    _live: LiveSlot,
}

fn ms(since: Instant) -> f64 {
    since.elapsed().as_secs_f64() * 1000.0
}

impl Engine {
    /// Loads the model. The model lives on the heap behind a raw pointer so the context can
    /// borrow it for `'static`; `Drop` frees both in order (Metal asserts at process exit if
    /// the context outlives its device). The backend is the process's (`backend`). An engine
    /// still being freed (the one this replaces) is waited for first, up to 10 s.
    pub fn load(cfg: &EngineConfig) -> Result<Self, String> {
        if !std::path::Path::new(&cfg.model_path).is_file() {
            return Err(format!("model file not found: {}", cfg.model_path));
        }
        let live = LiveSlot::acquire();
        let backend = backend()?;
        let mparams = LlamaModelParams::default().with_n_gpu_layers(cfg.n_gpu_layers);
        let model = match LlamaModel::load_from_file(backend, &cfg.model_path, &mparams) {
            Ok(m) => m,
            Err(e) => return Err(format!("model load: {e}")),
        };
        let rollback = if model.is_recurrent() || model.is_hybrid() { Rollback::Snapshot } else { Rollback::Truncate };
        let model_ptr = Box::into_raw(Box::new(model));
        // SAFETY: freed only in Drop, after the context that borrows it.
        let model: &'static LlamaModel = unsafe { &*model_ptr };
        // Beam search keeps extra sequences in one shared (unified) cache, where copying a
        // sequence only tags cells; recurrent state can't be shared that way.
        let beams = rollback == Rollback::Truncate;
        let cparams = LlamaContextParams::default()
            .with_n_ctx(NonZeroU32::new(cfg.n_ctx))
            .with_n_batch(cfg.n_batch)
            .with_n_ubatch(cfg.n_batch)
            .with_n_seq_max(if beams { 1 + 2 * MAX_BEAMS as u32 } else { 1 })
            .with_kv_unified(true)
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
            model: model_ptr,
            ctx: ManuallyDrop::new(ctx),
            batch: LlamaBatch::new((cfg.n_batch as usize).max(MAX_BEAMS), 1),
            cached: Vec::new(),
            pieces,
            eog,
            add_bos,
            n_batch: cfg.n_batch as usize,
            n_ctx: cfg.n_ctx as usize,
            vocab_bias: Vocabulary::default(),
            rollback,
            snapshots: VecDeque::new(),
            beams,
            _live: live,
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
            .take_while(|(_, c)| words::is_letter(*c) || *c == '\'' || *c == '\u{2019}')
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
    /// batch slot `0` of the last decode, computed: it returns once the GPU has finished.
    /// Returns how many tokens were prefilled.
    fn sync(&mut self, tokens: &[LlamaToken], cancel: &dyn Fn() -> bool) -> Result<usize, GenError> {
        if tokens.is_empty() {
            return Err(GenError::Failed("empty prompt".into()));
        }
        if tokens.len() + 64 > self.n_ctx {
            return Err(GenError::TooLong(tokens.len()));
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
        // llama.cpp returns from the last decode while the GPU still runs it and waits at the
        // first logits read. Wait here instead, so the prefill is timed in full and the
        // generation deadline doesn't start until the prompt is done.
        self.ctx.synchronize();
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

    /// Whether generating token `id` after `out` ends the suggestion, and how many of its
    /// bytes to keep (a newline keeps what comes before it). Shared by greedy and beam search.
    fn stop_before(&self, id: usize, out: &[u8], fragment: &[u8], opts: &GenOptions) -> Option<(&'static str, usize)> {
        if self.eog[id] {
            return Some(("eog", 0));
        }
        if out.len() < fragment.len() {
            return None;
        }
        let piece = &self.pieces[id];
        if let Some(nl) = piece.iter().position(|&b| b == b'\n') {
            return Some(("newline", nl));
        }
        // Starting a new word past the limit (or after a sentence end) ends the suggestion.
        let starts_word = piece.first().is_some_and(|b| b.is_ascii_whitespace());
        if starts_word {
            let shown = String::from_utf8_lossy(&out[fragment.len()..]);
            if words::count_words(&shown) >= opts.max_words {
                return Some(("words", 0));
            }
            if opts.stop_at_sentence_end && words::ends_sentence(&shown) {
                return Some(("sentence", 0));
            }
        }
        None
    }

    /// The `k` best allowed next tokens after `out` with their log-probabilities (the
    /// personal bias included, normalized over the whole vocabulary).
    fn top_k(&self, logits: &[f32], out: &[u8], prompt: &Prompt, opts: &GenOptions, k: usize) -> Vec<(LlamaToken, f32)> {
        let fragment = prompt.fragment.as_bytes();
        let remaining: &[u8] = if out.len() < fragment.len() { &fragment[out.len()..] } else { &[] };
        let bias: HashMap<usize, f32> = if opts.personal_strength > 0.0 {
            let full = if out.len() < fragment.len() { prompt.fragment.as_str() } else { std::str::from_utf8(out).unwrap_or("") };
            let mut m = HashMap::new();
            for (t, b) in self.step_bias(full, out.len(), opts.personal_strength) {
                let e = m.entry(t).or_insert(0.0f32);
                *e = e.max(b);
            }
            m
        } else {
            HashMap::new()
        };
        let max = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max);
        let lse = max + logits.iter().map(|l| (l - max).exp()).sum::<f32>().ln();
        let mut best: Vec<(usize, f32)> = Vec::with_capacity(k + 1);
        for (id, &l) in logits.iter().enumerate() {
            let v = l + bias.get(&id).copied().unwrap_or(0.0);
            if best.len() == k && best.last().is_some_and(|(_, b)| v <= *b) {
                continue;
            }
            if !self.allowed(id, remaining) {
                continue;
            }
            let at = best.partition_point(|(_, b)| *b >= v);
            best.insert(at, (id, v));
            best.truncate(k);
        }
        best.into_iter().map(|(id, v)| (LlamaToken(id as i32), v - lse)).collect()
    }

    /// Phrase beam search (TabType reports Cotypist uses a 9-wide one): keeps the
    /// `beam_width` most likely continuations, decoded together in one batch per step, and
    /// returns the phrase with the best average log-probability. The first word may differ
    /// from the greedy one. The prompt's sequence 0 is never written, so nothing needs
    /// rolling back. Returns (bytes generated, stop reason, decode steps).
    fn beam_search(
        &mut self,
        prompt: &Prompt,
        prompt_len: usize,
        opts: &GenOptions,
        cancel: &dyn Fn() -> bool,
        t_gen: Instant,
    ) -> Result<(Vec<u8>, &'static str, usize), GenError> {
        let width = opts.beam_width.clamp(1, MAX_BEAMS);
        let fragment = prompt.fragment.as_bytes();
        let max_tokens = opts.max_words * 3 + 8 + fragment.len();
        let mut finished: Vec<(Vec<u8>, f32, usize, &'static str)> = Vec::new();
        let mut bank = 0usize;
        let seq_of = |bank: usize, i: usize| (1 + bank * MAX_BEAMS + i) as i32;
        // First step: children of the prompt's last token (its logits are fresh from sync).
        let first = self.top_k(self.ctx.get_logits_ith(self.logits_index()), &[], prompt, opts, width);
        let mut beams: Vec<Beam> = Vec::new();
        for (tok, lp) in first {
            if let Some((reason, keep)) = self.stop_before(tok.0 as usize, &[], fragment, opts) {
                finished.push((self.pieces[tok.0 as usize][..keep].to_vec(), lp, 1, reason));
                continue;
            }
            let seq = seq_of(bank, beams.len());
            self.ctx.copy_kv_cache_seq(0, seq, None, None).map_err(|e| GenError::Failed(format!("seq copy: {e}")))?;
            beams.push(Beam { tokens: vec![tok], out: self.pieces[tok.0 as usize].clone(), score: lp, seq });
        }
        let mut steps = 1usize;
        let mut stop = "maxTokens";
        let result = loop {
            if beams.is_empty() {
                stop = "beams";
                break Ok(());
            }
            if steps >= max_tokens {
                break Ok(());
            }
            if cancel() {
                break Err(GenError::Cancelled);
            }
            if t_gen.elapsed() > opts.deadline {
                stop = "deadline";
                break Ok(());
            }
            self.batch.clear();
            let mut added = Ok(());
            for b in &beams {
                let pos = prompt_len + b.tokens.len() - 1;
                added = added.and_then(|_| self.batch.add(*b.tokens.last().unwrap(), pos as i32, &[b.seq], true));
            }
            if let Err(e) = added {
                break Err(GenError::Failed(format!("batch: {e}")));
            }
            if let Err(e) = self.ctx.decode(&mut self.batch) {
                break Err(GenError::Failed(format!("decode: {e}")));
            }
            steps += 1;
            // Children of every beam, best first.
            let mut children: Vec<(usize, LlamaToken, f32)> = Vec::new();
            for (i, b) in beams.iter().enumerate() {
                for (tok, lp) in self.top_k(self.ctx.get_logits_ith(i as i32), &b.out, prompt, opts, width) {
                    children.push((i, tok, b.score + lp));
                }
            }
            children.sort_by(|a, b| b.2.total_cmp(&a.2));
            let next_bank = 1 - bank;
            let mut next: Vec<Beam> = Vec::new();
            for (parent, tok, score) in children {
                if next.len() >= width {
                    break;
                }
                let p = &beams[parent];
                let id = tok.0 as usize;
                if let Some((reason, keep)) = self.stop_before(id, &p.out, fragment, opts) {
                    let mut out = p.out.clone();
                    out.extend_from_slice(&self.pieces[id][..keep]);
                    let n = p.tokens.len() + usize::from(keep > 0);
                    finished.push((out, if keep > 0 { score } else { p.score }, n, reason));
                    continue;
                }
                let seq = seq_of(next_bank, next.len());
                self.ctx.clear_kv_cache_seq(Some(seq as u32), None, None).map_err(|e| GenError::Failed(format!("seq clear: {e}")))?;
                self.ctx.copy_kv_cache_seq(p.seq, seq, None, None).map_err(|e| GenError::Failed(format!("seq copy: {e}")))?;
                let mut tokens = p.tokens.clone();
                tokens.push(tok);
                let mut out = p.out.clone();
                out.extend_from_slice(&self.pieces[id]);
                next.push(Beam { tokens, out, score, seq });
            }
            for b in &beams {
                let _ = self.ctx.clear_kv_cache_seq(Some(b.seq as u32), None, None);
            }
            beams = next;
            bank = next_bank;
            // Stop early when no live beam can still catch the best finished phrase: adding
            // tokens only lowers a sum of log-probabilities (a cautious test, since the final
            // choice compares means).
            let best_done = finished.iter().map(|(_, s, _, _)| *s).fold(f32::NEG_INFINITY, f32::max);
            if beams.iter().all(|b| b.score < best_done) {
                stop = "beams";
                break Ok(());
            }
        };
        // Unfinished beams compete too (cut to whole words by the caller).
        for b in &beams {
            finished.push((b.out.clone(), b.score, b.tokens.len(), stop));
            let _ = self.ctx.clear_kv_cache_seq(Some(b.seq as u32), None, None);
        }
        result?;
        let best = finished
            .into_iter()
            .filter(|(out, _, _, _)| out.len() >= fragment.len())
            .max_by(|a, b| mean_score(a.1, a.2).total_cmp(&mean_score(b.1, b.2)));
        Ok(match best {
            Some((out, _, _, reason)) => (out, reason, steps),
            None => (Vec::new(), "noCandidate", steps),
        })
    }

    pub fn complete(
        &mut self,
        prompt: &Prompt,
        opts: &GenOptions,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Completion, GenError> {
        let t0 = Instant::now();
        // Mid-line prompts are plain continuations too: Qwen3's FIM tokens produced noise
        // on prose (docs/MEASUREMENTS.md), so the rest of the line only trims the result.
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

        let result = if opts.beam_width > 1 && self.beams {
            // Beams live in their own sequences: the cache still holds exactly the prompt.
            self.beam_search(prompt, tokens.len(), opts, cancel, t_gen).map(|(o, s, n)| {
                out = o;
                stop = s;
                generated = n;
            })
        } else {
            loop {
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
            if let Some((reason, keep)) = self.stop_before(id, &out, fragment, opts) {
                out.extend_from_slice(&self.pieces[id][..keep]);
                stop = reason;
                break Ok(());
            }
            out.extend_from_slice(&self.pieces[id]);
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
            }
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
            if !prompt.suffix.is_empty() {
                text = before_suffix(&text, &prompt.suffix).to_string();
            }
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

/// Cuts a mid-line suggestion where it starts repeating the text after the caret: with the
/// rest of the line " is great.", "this is great" becomes "this" (and "is great" nothing).
fn before_suffix<'a>(shown: &'a str, suffix: &str) -> &'a str {
    let suf = suffix.trim_start();
    let starts = std::iter::once(0).chain(shown.char_indices().filter(|(_, c)| c.is_whitespace()).map(|(i, _)| i));
    for k in starts {
        let rest = shown[k..].trim();
        if !rest.is_empty() && suf.starts_with(rest) {
            return shown[..k].trim_end();
        }
    }
    shown
}

impl Drop for Engine {
    fn drop(&mut self) {
        // SAFETY: context first (it borrows the model), then the model; neither is used
        // again. The backend is the process's and stays.
        unsafe {
            ManuallyDrop::drop(&mut self.ctx);
            drop(Box::from_raw(self.model));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{backend, before_suffix};

    /// The shell replaces an engine while the old one is alive: a second backend request
    /// must not fail (llama-cpp-2 refuses a second `LlamaBackend::init`).
    #[test]
    fn the_backend_is_shared_across_engines() {
        let a = backend().expect("first backend");
        let b = std::thread::spawn(|| backend().map(|b| b as *const _ as usize)).join().unwrap().expect("second backend");
        assert_eq!(a as *const _ as usize, b);
    }

    #[test]
    fn mid_line_suggestion_stops_where_the_line_resumes() {
        assert_eq!(before_suffix("this is great", " is great."), "this");
        assert_eq!(before_suffix("is great", " is great."), "");
        assert_eq!(before_suffix("ould", " split the work"), "ould");
        assert_eq!(before_suffix("ould split", " split the work"), "ould");
        assert_eq!(before_suffix("really nice", " day"), "really nice");
    }
}
