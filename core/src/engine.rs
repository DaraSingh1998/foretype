//! In-process llama.cpp inference tuned for keystroke-rate completion.
//!
//! - One llama.cpp context holding a few prompts at once, each in its own sequence (a
//!   *slot*). Every request is reconciled against the tokens already in a slot: the longest
//!   common prefix is kept and only the new tail is prefilled. Generated tokens are rolled
//!   back afterwards, so a slot always mirrors its prompt.
//! - Double buffering (D47): a prompt whose header changed (other apps' text, the screen
//!   text) is prefilled in a second slot in small chunks between keystrokes
//!   (`set_background`, `background_step`), while the shell's keystrokes keep being served
//!   from the slot holding the old header; the next request that finds its prompt in the new
//!   slot switches to it. Slots share the cells of a common prefix (`seq_cp`), so a new
//!   screen text under the same other-apps section only costs its own tokens.
//! - Saved contexts: a slot about to be reused for another field is first copied out of the
//!   KV cache (`llama_state_seq_get_data`) into a small LRU in memory, so returning to that
//!   field restores it instead of prefilling it again.
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

use llama_cpp_2::context::params::{KvCacheType, LlamaContextParams};
use llama_cpp_2::context::session::{LlamaStateSeqFlags, SeqState};
use llama_cpp_2::context::LlamaContext;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::token::LlamaToken;
use llama_cpp_2::DecodeError;

use crate::context::Prompt;
use crate::words;

#[derive(Debug, Clone)]
pub struct EngineConfig {
    pub model_path: String,
    /// The longest prompt, plus 64 tokens: a longer prompt fails with `TooLong`.
    pub n_ctx: u32,
    pub n_batch: u32,
    pub n_gpu_layers: u32,
    pub n_threads: i32,
    /// The KV cache's element type: "f16" or "q8_0" (half the memory, a little slower per
    /// token on short prompts; needs flash attention, which llama.cpp turns on by itself on
    /// Metal).
    pub kv_type: String,
    /// Flash attention: None lets llama.cpp decide (on wherever the backend supports it).
    pub flash_attn: Option<bool>,
    /// Prompts held at once (D47): 2 lets a new header prefill in the background while the
    /// old one serves. Recurrent and hybrid models always get 1.
    pub slots: usize,
    /// Cells in the KV cache, shared by the slots and beam search; 0 = `n_ctx` per slot.
    pub kv_cells: u32,
    /// Most bytes of saved contexts kept in memory (0 = none).
    pub saved_bytes: usize,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            model_path: String::new(),
            n_ctx: 2048,
            n_batch: 512,
            n_gpu_layers: 999,
            n_threads: 4,
            kv_type: "f16".into(),
            flash_attn: None,
            slots: 2,
            kv_cells: 0,
            saved_bytes: 0,
        }
    }
}

impl EngineConfig {
    /// Cells the KV cache gets for this many slots.
    pub fn cells(&self, slots: usize) -> u32 {
        if self.kv_cells > 0 {
            self.kv_cells.max(self.n_ctx)
        } else {
            self.n_ctx * slots.max(1) as u32
        }
    }
}

fn kv_cache_type(name: &str) -> Result<KvCacheType, String> {
    match name {
        "" | "f16" => Ok(KvCacheType::F16),
        "q8_0" => Ok(KvCacheType::Q8_0),
        "q4_0" => Ok(KvCacheType::Q4_0),
        "f32" => Ok(KvCacheType::F32),
        other => Err(format!("unknown KV cache type {other:?}")),
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

/// Most beams a context is set up for: beams live in the 2*MAX_BEAMS sequences after the
/// slots' (two banks, swapped every step); the serving slot's sequence holds the prompt.
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

/// One prompt held in the KV cache: a llama.cpp sequence and the tokens in it.
struct Slot {
    seq: i32,
    cached: Vec<LlamaToken>,
    /// `Engine::tick` when it last served or was prefilled.
    used: u64,
}

/// A slot's context copied out of the KV cache, to restore when its field comes back.
struct Saved {
    tokens: Vec<LlamaToken>,
    state: SeqState,
    at: Instant,
}

/// A slot worth saving before it is reused holds at least this many tokens (a header with
/// other apps' or screen text; a bare field prefills fast anyway).
const MIN_SAVE_TOKENS: usize = 256;

/// A restore counts as this many prefilled tokens when choosing where a prompt comes from
/// (it copies the whole saved state back: a few milliseconds per thousand tokens).
const RESTORE_COST: usize = 32;

/// Saved contexts are dropped after 10 minutes, like other apps' text itself (D42).
const SAVED_MAX_AGE: Duration = Duration::from_secs(600);

/// A slot is reused in place when the new prompt keeps three quarters of it or loses at
/// most this many tokens (typing, deleting a word, the body window moving).
const IN_PLACE_LOSS: usize = 256;

/// Where a prompt's context comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Source {
    Slot(usize),
    Saved(usize),
}

/// A token id, for callers that tokenize once and pass the tokens around.
pub type Token = LlamaToken;

fn common_prefix(a: &[LlamaToken], b: &[LlamaToken]) -> usize {
    a.iter().zip(b).take_while(|(x, y)| x == y).count()
}

/// What `background_step` did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Background {
    /// Nothing to prefill.
    Idle,
    /// Prefilled `n` more tokens; more to do.
    Working(usize),
    /// The background prompt is in a slot: the next request for it starts there.
    Ready,
}

/// The KV cache's contents, for logs and measurements.
#[derive(Debug, Clone, Default)]
pub struct CacheStats {
    /// Tokens held per slot, and which slot serves.
    pub slots: Vec<usize>,
    pub active: usize,
    /// Saved contexts and their bytes.
    pub saved: usize,
    pub saved_bytes: usize,
    /// Tokens the background prompt still needs.
    pub background_left: usize,
    /// Background prompts finished, and how long the last one took from the request that
    /// started it (milliseconds; updates of the same prompt as typing goes on included).
    pub ready: u64,
    pub last_ready_ms: f64,
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
    /// Prompts in the KV cache (sequences 0..slots); `active` served the last request.
    slots: Vec<Slot>,
    active: usize,
    /// The prompt to prefill between requests, and the slot it goes to.
    background: Option<Vec<LlamaToken>>,
    /// Tokens per background step, adjusted so a step takes about the time asked for.
    bg_chunk: usize,
    /// When the current background prompt was first asked for, background prompts finished
    /// and the time the last one took.
    bg_since: Option<Instant>,
    bg_ready: u64,
    bg_last_ms: f64,
    /// Saved contexts, oldest first, and their total size and limit in bytes.
    saved: VecDeque<Saved>,
    saved_bytes: usize,
    saved_limit: usize,
    tick: u64,
    /// Detokenized bytes of every vocabulary entry (empty for control tokens).
    pieces: Vec<Vec<u8>>,
    eog: Vec<bool>,
    add_bos: bool,
    n_batch: usize,
    n_ctx: usize,
    vocab_bias: Vocabulary,
    rollback: Rollback,
    snapshots: VecDeque<StateSnapshot>,
    /// The context has room for beam-search sequences (truncating models only); they come
    /// after the slots' sequences.
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
        // Beam search and the slots keep extra sequences in one shared (unified) cache, where
        // copying a sequence only tags cells; recurrent state can't be shared that way, so
        // recurrent models get one slot and no beams.
        let beams = rollback == Rollback::Truncate;
        let n_slots = if beams { cfg.slots.clamp(1, 4) } else { 1 };
        let kv_type = match kv_cache_type(&cfg.kv_type) {
            Ok(t) => t,
            Err(e) => {
                drop(unsafe { Box::from_raw(model_ptr) });
                return Err(e);
            }
        };
        let mut cparams = LlamaContextParams::default()
            .with_n_ctx(NonZeroU32::new(cfg.cells(n_slots)))
            .with_n_batch(cfg.n_batch)
            .with_n_ubatch(cfg.n_batch)
            .with_n_seq_max(n_slots as u32 + if beams { 2 * MAX_BEAMS as u32 } else { 0 })
            .with_kv_unified(true)
            // Sliding-window layers normally overwrite cells that left the window, which
            // makes rolling back impossible; at a 2,048-token context the full-size cache
            // costs little.
            .with_swa_full(true)
            .with_type_k(kv_type)
            .with_type_v(kv_type)
            .with_n_threads(cfg.n_threads)
            .with_n_threads_batch(cfg.n_threads);
        if let Some(on) = cfg.flash_attn {
            cparams = cparams.with_flash_attention_policy(i32::from(on));
        }
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
            slots: (0..n_slots).map(|i| Slot { seq: i as i32, cached: Vec::new(), used: 0 }).collect(),
            active: 0,
            background: None,
            bg_chunk: 32,
            bg_since: None,
            bg_ready: 0,
            bg_last_ms: 0.0,
            saved: VecDeque::new(),
            saved_bytes: 0,
            saved_limit: if beams { cfg.saved_bytes } else { 0 },
            tick: 0,
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

    /// Prompts this engine holds at once (1 for recurrent models).
    pub fn slot_count(&self) -> usize {
        self.slots.len()
    }

    pub fn stats(&self) -> CacheStats {
        CacheStats {
            slots: self.slots.iter().map(|s| s.cached.len()).collect(),
            active: self.active,
            saved: self.saved.len(),
            saved_bytes: self.saved_bytes,
            background_left: self.background.as_ref().map_or(0, |t| self.cost(t).saturating_sub(1)),
            ready: self.bg_ready,
            last_ready_ms: self.bg_last_ms,
        }
    }

    /// Empties the cache and drops all snapshots, saved contexts and the background prompt
    /// (the next request prefills from scratch). Also how other apps' text is forgotten.
    pub fn reset(&mut self) {
        self.ctx.clear_kv_cache();
        for s in &mut self.slots {
            s.cached.clear();
        }
        self.snapshots.clear();
        self.saved.clear();
        self.saved_bytes = 0;
        self.background = None;
        self.bg_since = None;
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

    /// Tokens a request for `tokens` would prefill: what is left after the longest prefix a
    /// slot or a saved context shares with it (a restore counts `RESTORE_COST` more). The
    /// prompt's last token is always decoded again, so the least is 1.
    pub fn cost(&self, tokens: &[LlamaToken]) -> usize {
        let n = tokens.len();
        if n == 0 {
            return 0;
        }
        n - self.best_source(tokens).1.min(n - 1)
    }

    /// The slot or saved context sharing the longest prefix with `tokens`, and how much of
    /// it counts (a saved context's prefix minus `RESTORE_COST`). The serving slot wins ties.
    fn best_source(&self, tokens: &[LlamaToken]) -> (Option<Source>, usize) {
        let mut best: (Option<Source>, usize) = (None, 0);
        for (i, s) in self.slots.iter().enumerate() {
            let l = common_prefix(&s.cached, tokens);
            if best.0.is_none() || l > best.1 || (l == best.1 && i == self.active) {
                best = (Some(Source::Slot(i)), l);
            }
        }
        for (i, e) in self.saved.iter().enumerate() {
            if e.at.elapsed() > SAVED_MAX_AGE {
                continue;
            }
            let l = common_prefix(&e.tokens, tokens).saturating_sub(RESTORE_COST);
            if l > best.1 {
                best = (Some(Source::Saved(i)), l);
            }
        }
        best
    }

    /// Chooses the slot `tokens` will be prefilled in and seeds it with the longest prefix
    /// at hand. A slot whose prompt this one extends or cuts back a little is used in place;
    /// otherwise the least recently used slot other than the serving one is taken (its
    /// prompt saved first when it is long), and gets the prefix copied from another slot
    /// (shared cells, no copy of data) or restored from a saved context.
    fn place(&mut self, tokens: &[LlamaToken], background: bool) -> usize {
        if self.slots.len() == 1 {
            return 0;
        }
        let (src, have) = self.best_source(tokens);
        let mut in_place: Option<(usize, usize)> = None;
        for (i, s) in self.slots.iter().enumerate() {
            if background && i == self.active {
                continue;
            }
            let l = common_prefix(&s.cached, tokens);
            let loss = s.cached.len() - l;
            if (loss <= IN_PLACE_LOSS || l * 4 >= s.cached.len() * 3) && in_place.is_none_or(|(_, b)| l > b) {
                in_place = Some((i, l));
            }
        }
        if let Some((i, l)) = in_place {
            if l >= have {
                return i;
            }
        }
        let dest = (0..self.slots.len())
            .filter(|&i| i != self.active)
            .min_by_key(|&i| self.slots[i].used)
            .unwrap_or(self.active);
        match src {
            Some(Source::Slot(j)) if j == dest => {
                // Its own prefix is the best there is: cut it back (rewinding needs no save).
                if self.rewind(dest, &tokens[..have]).is_err() {
                    self.clear_slot(dest);
                }
            }
            Some(Source::Slot(j)) if have > 0 => {
                self.save_slot(dest);
                self.clear_slot(dest);
                let (from, to) = (self.slots[j].seq, self.slots[dest].seq);
                if self.ctx.copy_kv_cache_seq(from, to, Some(0), Some(have as u32)).is_ok() {
                    self.slots[dest].cached = tokens[..have].to_vec();
                }
            }
            Some(Source::Saved(k)) => {
                // Out of the list first: saving the slot may drop the oldest entries.
                let e = self.saved.remove(k).expect("index from best_source");
                self.saved_bytes -= e.state.byte_len();
                self.save_slot(dest);
                self.clear_slot(dest);
                let l = have + RESTORE_COST;
                let seq = self.slots[dest].seq;
                // The restored sequence must reach position l - 1 (llama.cpp checks only
                // the state's shape).
                let ok = self.ctx.state_seq_set(&e.state, seq).is_ok()
                    && self.ctx.kv_cache_seq_pos_max(seq) + 1 >= l as i32
                    && self.ctx.clear_kv_cache_seq(Some(seq as u32), Some(l as u32), None).unwrap_or(false);
                if ok {
                    self.slots[dest].cached = tokens[..l].to_vec();
                } else {
                    self.clear_slot(dest);
                }
                self.saved_bytes += e.state.byte_len();
                self.saved.push_back(e);
                self.trim_saved();
            }
            _ => {
                self.save_slot(dest);
                self.clear_slot(dest);
            }
        }
        dest
    }

    fn clear_slot(&mut self, i: usize) {
        let _ = self.ctx.clear_kv_cache_seq(Some(self.slots[i].seq as u32), None, None);
        self.slots[i].cached.clear();
    }

    /// Copies slot `i`'s prompt out of the KV cache before the slot is reused, when it is
    /// long enough to be worth restoring and not saved already. Oldest saves go first when
    /// over the limit.
    fn save_slot(&mut self, i: usize) {
        if self.saved_limit == 0 || self.slots[i].cached.len() < MIN_SAVE_TOKENS {
            return;
        }
        self.expire_saved();
        let tokens = &self.slots[i].cached;
        if let Some(k) = self.saved.iter().position(|e| e.tokens.starts_with(tokens)) {
            let e = self.saved.remove(k).expect("index from iter");
            self.saved.push_back(e);
            return;
        }
        // A save of a shorter prompt this one continues (the same field, typed further).
        self.saved.retain(|e| !tokens.starts_with(&e.tokens));
        match self.ctx.state_seq_get(self.slots[i].seq, LlamaStateSeqFlags::empty()) {
            Ok(state) if state.byte_len() <= self.saved_limit => {
                self.saved.push_back(Saved { tokens: tokens.clone(), state, at: Instant::now() });
            }
            Ok(_) => {}
            Err(e) => eprintln!("[foretype] saving a context failed: {e}"),
        }
        self.trim_saved();
    }

    /// Drops the oldest saved contexts until they fit `saved_limit`.
    fn trim_saved(&mut self) {
        let mut total: usize = self.saved.iter().map(|e| e.state.byte_len()).sum();
        while total > self.saved_limit {
            let Some(e) = self.saved.pop_front() else { break };
            total -= e.state.byte_len();
        }
        self.saved_bytes = total;
    }

    /// Drops saved contexts older than `SAVED_MAX_AGE` (they may hold other apps' text).
    fn expire_saved(&mut self) {
        if self.saved.iter().any(|e| e.at.elapsed() > SAVED_MAX_AGE) {
            self.saved.retain(|e| e.at.elapsed() <= SAVED_MAX_AGE);
            self.saved_bytes = self.saved.iter().map(|e| e.state.byte_len()).sum();
        }
    }

    /// Makes the serving slot hold exactly `tokens` and leaves the logits of the last token
    /// in batch slot `0` of the last decode, computed: it returns once the GPU has finished.
    /// Returns how many tokens were prefilled.
    fn sync(&mut self, tokens: &[LlamaToken], cancel: &dyn Fn() -> bool) -> Result<usize, GenError> {
        if tokens.is_empty() {
            return Err(GenError::Failed("empty prompt".into()));
        }
        if tokens.len() + 64 > self.n_ctx {
            return Err(GenError::TooLong(tokens.len()));
        }
        self.expire_saved();
        let s = self.place(tokens, false);
        self.active = s;
        self.tick += 1;
        self.slots[s].used = self.tick;
        let common = common_prefix(&self.slots[s].cached, tokens);
        // The last prompt token must be decoded again: its logits were overwritten by
        // whatever was generated after it last time.
        let keep = common.min(tokens.len() - 1);
        if keep < self.slots[s].cached.len() {
            self.rewind(s, &tokens[..keep])?;
        }
        let start = self.slots[s].cached.len();
        let last = tokens.len() - 1;
        if self.rollback == Rollback::Snapshot {
            // Snapshot the state before the last token: the next keystroke in the same word
            // sends the same prompt, and generation is undone by returning here.
            self.decode(s, tokens, start, last, cancel)?;
            self.snapshot();
            self.decode(s, tokens, last, tokens.len(), cancel)?;
        } else {
            self.decode(s, tokens, start, tokens.len(), cancel)?;
        }
        // llama.cpp returns from the last decode while the GPU still runs it and waits at the
        // first logits read. Wait here instead, so the prefill is timed in full and the
        // generation deadline doesn't start until the prompt is done.
        self.ctx.synchronize();
        Ok(tokens.len() - start)
    }

    /// Decodes `tokens[from..to]` into slot `s` (which holds `tokens[..from]`), requesting
    /// logits only for the prompt's final token. When the cache has no room, the slots
    /// neither being filled nor serving are emptied and the batch is tried once more.
    fn decode(&mut self, s: usize, tokens: &[LlamaToken], from: usize, to: usize, cancel: &dyn Fn() -> bool) -> Result<(), GenError> {
        let seq = self.slots[s].seq;
        for (ci, chunk) in tokens[from..to].chunks(self.n_batch).enumerate() {
            if ci > 0 && cancel() {
                return Err(GenError::Cancelled);
            }
            let base = from + ci * self.n_batch;
            for attempt in 0..2 {
                self.batch.clear();
                for (i, &t) in chunk.iter().enumerate() {
                    let is_last = base + i == tokens.len() - 1;
                    self.batch
                        .add(t, (base + i) as i32, &[seq], is_last)
                        .map_err(|e| GenError::Failed(format!("batch: {e}")))?;
                }
                match self.ctx.decode(&mut self.batch) {
                    Ok(()) => break,
                    Err(DecodeError::NoKvCacheSlot) if attempt == 0 && self.make_room(s) => continue,
                    Err(e) => return Err(GenError::Failed(format!("decode: {e}"))),
                }
            }
            self.slots[s].cached.extend_from_slice(chunk);
        }
        Ok(())
    }

    /// Empties the slots other than `keep` and the serving one. False if there were none
    /// with anything in them.
    fn make_room(&mut self, keep: usize) -> bool {
        let mut freed = false;
        for i in 0..self.slots.len() {
            if i != keep && i != self.active && !self.slots[i].cached.is_empty() {
                self.clear_slot(i);
                freed = true;
            }
        }
        freed
    }

    /// Takes slot `s` back so it holds a prefix of `target` (all of it when possible).
    fn rewind(&mut self, s: usize, target: &[LlamaToken]) -> Result<(), GenError> {
        let n = target.len();
        let seq = self.slots[s].seq;
        match self.rollback {
            Rollback::Truncate => {
                let ok = self
                    .ctx
                    .clear_kv_cache_seq(Some(seq as u32), Some(n as u32), None)
                    .map_err(|e| GenError::Failed(format!("kv rollback: {e}")))?;
                if ok {
                    self.slots[s].cached.truncate(n);
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
                    let restored = self.ctx.state_seq_set(&snap.state, seq).is_ok()
                        && self.ctx.clear_kv_cache_seq(Some(seq as u32), Some(len as u32), None).unwrap_or(false);
                    self.snapshots.push_back(snap);
                    if restored {
                        self.slots[s].cached.truncate(len);
                        return Ok(());
                    }
                }
            }
        }
        // No way back to a shared prefix: start over.
        self.clear_slot(s);
        Ok(())
    }

    /// Records the recurrent state for the tokens now in the cache (once per prompt).
    /// Recurrent models have one slot.
    fn snapshot(&mut self) {
        let cached = &self.slots[0].cached;
        if let Some(i) = self.snapshots.iter().position(|s| &s.tokens == cached) {
            let s = self.snapshots.remove(i).expect("index from iter");
            self.snapshots.push_back(s);
            return;
        }
        match self.ctx.state_seq_get(self.slots[0].seq, LlamaStateSeqFlags::PARTIAL_ONLY) {
            Ok(state) => {
                if self.snapshots.len() >= MAX_SNAPSHOTS {
                    self.snapshots.pop_front();
                }
                self.snapshots.push_back(StateSnapshot { tokens: self.slots[0].cached.clone(), state });
            }
            Err(e) => eprintln!("[foretype] state snapshot failed: {e}"),
        }
    }

    /// Zero-token request: prefills `prefix` in the serving slot so the next completion
    /// only pays for its tail.
    pub fn warm(&mut self, prefix: &str, cancel: &dyn Fn() -> bool) -> Result<usize, GenError> {
        let tokens = self.tokenize(prefix);
        self.sync(&tokens, cancel)
    }

    /// The prompt to prefill between requests (replacing any earlier one): a new header the
    /// serving slot doesn't have yet. `background_step` does the work.
    pub fn set_background(&mut self, tokens: Vec<LlamaToken>) {
        if tokens.is_empty() {
            self.background = None;
            self.bg_since = None;
            return;
        }
        if self.background.is_none() || self.bg_since.is_none() {
            self.bg_since = Some(Instant::now());
        }
        self.background = Some(tokens);
    }

    /// A request was served with its own prompt: whatever background prompt there was is
    /// done (counted as ready if it had started).
    pub fn finish_background(&mut self) {
        if self.background.take().is_some() {
            self.background_done();
        }
        self.bg_since = None;
    }

    fn background_done(&mut self) -> Background {
        if let Some(t) = self.bg_since.take() {
            self.bg_ready += 1;
            self.bg_last_ms = ms(t);
        }
        Background::Ready
    }

    /// Prefills the next piece of the background prompt: about `max_ms` of work, into a slot
    /// other than the serving one, so a keystroke arriving meanwhile waits at most that long
    /// and is served from the old prompt. The piece grows or shrinks (at most twice or half
    /// as many tokens a step, 16 at least) until a step takes `max_ms`: a decode costs a
    /// fixed 10–20 ms before its first token, so a rate measured on small pieces would keep
    /// them small. The prompt's last token is left for the request that uses it. With one slot
    /// (recurrent models) the whole prompt is prefilled in place, cancellable between
    /// batches, as before double buffering.
    pub fn background_step(&mut self, max_ms: f64, cancel: &dyn Fn() -> bool) -> Background {
        self.expire_saved();
        let Some(target) = self.background.take() else { return Background::Idle };
        if target.len() < 2 || target.len() + 64 > self.n_ctx {
            self.bg_since = None;
            return Background::Idle;
        }
        if self.slots.iter().any(|s| common_prefix(&s.cached, &target) + 1 >= target.len()) {
            return self.background_done();
        }
        if self.slots.len() == 1 {
            return match self.sync(&target, cancel) {
                Err(GenError::Cancelled) => {
                    self.background = Some(target);
                    Background::Working(0)
                }
                _ => self.background_done(),
            };
        }
        let s = self.place(&target, true);
        self.tick += 1;
        self.slots[s].used = self.tick;
        let common = common_prefix(&self.slots[s].cached, &target);
        if common < self.slots[s].cached.len() && self.rewind(s, &target[..common]).is_err() {
            self.clear_slot(s);
        }
        let from = self.slots[s].cached.len();
        if from + 1 >= target.len() {
            // A saved context restored into the slot held it all.
            return self.background_done();
        }
        let n = self.bg_chunk.clamp(16, self.n_batch);
        let to = (from + n).min(target.len() - 1);
        let t = Instant::now();
        let never = || false;
        match self.decode(s, &target, from, to, &never) {
            Ok(()) => {
                self.ctx.synchronize();
                let took = ms(t);
                if to - from == n && took > 1.0 {
                    self.bg_chunk = ((n as f64 * (max_ms / took).clamp(0.5, 2.0)) as usize).clamp(16, self.n_batch);
                }
                if to + 1 >= target.len() {
                    self.background_done()
                } else {
                    self.background = Some(target);
                    Background::Working(to - from)
                }
            }
            Err(e) => {
                // No room for two prompts: the next request prefills it in the foreground.
                eprintln!("[foretype] background prefill stopped: {e:?}");
                self.clear_slot(s);
                self.bg_since = None;
                Background::Idle
            }
        }
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
    /// from the greedy one. The prompt's sequence is never written, so nothing needs
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
        let base = self.slots.len();
        let prompt_seq = self.slots[self.active].seq;
        let seq_of = |bank: usize, i: usize| (base + bank * MAX_BEAMS + i) as i32;
        // First step: children of the prompt's last token (its logits are fresh from sync).
        let first = self.top_k(self.ctx.get_logits_ith(self.logits_index()), &[], prompt, opts, width);
        let mut beams: Vec<Beam> = Vec::new();
        for (tok, lp) in first {
            if let Some((reason, keep)) = self.stop_before(tok.0 as usize, &[], fragment, opts) {
                finished.push((self.pieces[tok.0 as usize][..keep].to_vec(), lp, 1, reason));
                continue;
            }
            let seq = seq_of(bank, beams.len());
            self.ctx.copy_kv_cache_seq(prompt_seq, seq, None, None).map_err(|e| GenError::Failed(format!("seq copy: {e}")))?;
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
        // Mid-line prompts are plain continuations too: Qwen3's FIM tokens produced noise
        // on prose (docs/MEASUREMENTS.md), so the rest of the line only trims the result.
        let tokens = self.tokenize(&prompt.prefix);
        self.complete_tokens(&tokens, prompt, opts, cancel)
    }

    /// `complete` for a prompt already tokenized (`tokens` is `prompt.prefix`'s).
    pub fn complete_tokens(
        &mut self,
        tokens: &[LlamaToken],
        prompt: &Prompt,
        opts: &GenOptions,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Completion, GenError> {
        let t0 = Instant::now();
        let prefilled = self.sync(tokens, cancel)?;
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
            if let Err(e) = self.batch.add(tok, pos as i32, &[self.slots[self.active].seq], true) {
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
            self.rewind(self.active, target)?;
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
