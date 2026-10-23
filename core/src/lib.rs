//! Foretype core: the platform-independent half of a system-wide inline autocomplete app.
//!
//! A native shell (Swift on macOS today) captures the focused text field, sends a
//! [`Snapshot`] per change, and renders whatever suggestion state comes back. This crate
//! owns everything in between: the policy gate, suggestion reuse (type-through, cache,
//! word-by-word accept), prompt building and llama.cpp inference on a dedicated thread.
//! It emits suggestion *state*, never pixels, so the same engine can sit behind an overlay
//! (macOS), a TSF text service (Windows) or an Fcitx5/IBus preedit (Linux).

pub mod backend;
pub mod context;
pub mod details;
pub mod emoji;
pub mod engine;
pub mod ffi;
pub mod hinglish;
pub mod history;
pub mod instructions;
pub mod models;
pub mod others;
pub mod policy;
pub mod profile;
pub mod session;
pub mod words;

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::context::{ContextInput, Prompt};
use crate::details::UserDetails;
use crate::engine::{Background, CacheStats, Engine, EngineConfig, GenError, GenOptions};
use crate::history::{History, Record};
use crate::others::{OtherApps, Passage, Query};
use crate::policy::CompatDb;
use crate::profile::Profile;
use crate::session::{AcceptMode, Accepted, Session};

/// One read of the focused field, sent by the shell on every change.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Snapshot {
    /// Monotonic per shell; results for older revisions are dropped.
    pub revision: u64,
    /// Identifies the field (app + element). Changes on focus change.
    pub field_key: u64,
    pub bundle_id: String,
    pub app_name: String,
    pub window_title: String,
    pub url: String,
    pub role: String,
    pub subrole: String,
    pub role_description: String,
    /// The field's accessible label or placeholder (aria-label in web and Electron apps).
    pub description: String,
    /// Text before the caret. Shells should send a window whose start moves in coarse,
    /// aligned steps so the prompt prefix stays stable.
    pub text_before: String,
    /// Text after the caret up to the end of the line.
    pub text_after: String,
    /// OCR of on-screen text near the field (optional; empty when screen context is off).
    pub screen_context: String,
    pub selection_len: i64,
    pub marked_len: i64,
    pub secure_input: bool,
    pub field_width: f64,
    pub field_height: f64,
    /// The user explicitly asked for suggestions here (overrides soft policy rules).
    pub force: bool,
    /// The platform spell checker's verdict on the partial word at the caret: "word" (a
    /// word already), "prefix" (can still become one), "typo" (can't), or "" (not checked).
    pub spell_fragment: String,
    /// The word just finished (the text before the caret ends with it and spaces) when the
    /// spell checker flags it, and its correction; both empty otherwise.
    pub spell_word: String,
    pub spell_correction: String,
}

/// User-facing settings, sent as JSON through `ft_engine_configure`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct Settings {
    pub enabled: bool,
    /// Everything stops (the user paused, or the shell's power rules did): queued work is
    /// dropped, a running completion is cancelled, the model is freed at once and the worker
    /// sleeps; `submit` answers with a `paused` hide and `warm` does nothing. The model loads
    /// again on the first job after the pause ends.
    pub paused: bool,
    /// Maximum words per suggestion (Cotypist-style presets: 2, 4, 7, 10).
    pub length_words: usize,
    pub stop_at_sentence_end: bool,
    pub instructions: String,
    /// Extra instructions per bundle ID, appended after the global ones.
    pub app_instructions: HashMap<String, String>,
    pub disabled_apps: Vec<String>,
    pub enabled_apps: Vec<String>,
    /// When non-empty, suggest only in these apps (development and testing safety net).
    pub only_apps: Vec<String>,
    pub deadline_ms: u64,
    pub max_body_chars: usize,
    /// Free the model after this many idle seconds (0 = never); it reloads on next use.
    pub unload_after_s: u64,
    /// Wait this long for more typing before generating mid-word (0 = never wait). Shells
    /// raise it on battery power.
    pub debounce_ms: u64,
    /// After showing a suggestion, compute the one that would follow it, so accepting the
    /// whole suggestion (or typing through it) shows the next one instantly.
    pub prefetch: bool,
    /// Learn from the user's writing (opt-in): record accepted-in fields to the encrypted
    /// history, bias word choice and show the model short examples from the same app.
    pub personalize: bool,
    /// 0 gentle, 1 balanced, 2 strong.
    pub personalize_strength: u8,
    pub personal_examples: bool,
    /// Offer an emoji for a typed `:name` (accepting replaces the shortcode).
    pub emoji: bool,
    /// Offer the spell checker's correction for a misspelled word just finished.
    pub autocorrect: bool,
    /// No suggestion while the partial word can't become a real word (Cotypist's rule).
    pub typo_gate: bool,
    /// Suggest in the middle of a line too (built-in engine; at most 3 words, cut where the
    /// suggestion would repeat the rest of the line).
    pub mid_line: bool,
    /// Phrase beam search width (1 = greedy).
    pub beam_width: usize,
    /// Most tokens the other-apps section may take (D42, D44: the macOS shell sends 512 on
    /// Macs under 16 GB, 2,048 provisionally from 16 GB). The section also leaves room for the
    /// rest of the prompt within `n_ctx` − 64; 0 turns it off.
    pub other_apps_tokens: usize,
}

impl Settings {
    /// Logit boost at full weight for the strength setting.
    pub fn personal_strength(&self) -> f32 {
        if !self.personalize {
            return 0.0;
        }
        match self.personalize_strength {
            0 => 1.0,
            1 => 2.0,
            _ => 4.0,
        }
    }

    fn instructions_for(&self, bundle_id: &str) -> String {
        match self.app_instructions.get(bundle_id).map(|s| s.trim()).filter(|s| !s.is_empty()) {
            Some(app) if !self.instructions.trim().is_empty() => format!("{} {}", self.instructions.trim(), app),
            Some(app) => app.to_string(),
            None => self.instructions.trim().to_string(),
        }
    }
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            enabled: true,
            paused: false,
            length_words: 4,
            stop_at_sentence_end: true,
            instructions: String::new(),
            app_instructions: HashMap::new(),
            disabled_apps: Vec::new(),
            enabled_apps: Vec::new(),
            only_apps: Vec::new(),
            deadline_ms: 300,
            max_body_chars: 1600,
            unload_after_s: 300,
            debounce_ms: 0,
            prefetch: true,
            personalize: false,
            personalize_strength: 1,
            personal_examples: true,
            emoji: true,
            autocorrect: true,
            typo_gate: true,
            mid_line: false,
            beam_width: 1,
            other_apps_tokens: 512,
        }
    }
}

/// Engine configuration, sent once as JSON to `ft_engine_new`.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct CoreConfig {
    pub model_path: String,
    pub n_ctx: u32,
    pub n_gpu_layers: u32,
    pub n_threads: i32,
    pub settings: Settings,
    /// Encrypted writing history (personalization). Empty path or key = memory only.
    pub history_path: String,
    /// 256-bit key as 64 hex characters, kept by the shell in the platform keystore.
    pub history_key_hex: String,
    /// "local" (in-process llama.cpp, default), "llama-server", "openai", or "shell" (the
    /// completer the shell installs with `ft_engine_set_completer`).
    pub backend: String,
    pub backend_url: String,
    /// Model name for OpenAI-compatible servers.
    pub backend_model: String,
    pub backend_api_key: String,
    /// The built-in engine's KV cache (D47): element type ("f16" or "q8_0"), prompts held at
    /// once (2: a new header prefills in the background while the old one serves), cells
    /// (0: `n_ctx` per slot), memory for saved contexts in MB, and flash attention (absent:
    /// llama.cpp decides).
    pub kv_type: String,
    pub slots: usize,
    pub kv_cells: u32,
    pub saved_mb: usize,
    pub flash_attn: Option<bool>,
}

impl Default for CoreConfig {
    fn default() -> Self {
        let e = EngineConfig::default();
        Self {
            model_path: String::new(),
            n_ctx: e.n_ctx,
            n_gpu_layers: e.n_gpu_layers,
            n_threads: e.n_threads,
            settings: Settings::default(),
            history_path: String::new(),
            history_key_hex: String::new(),
            backend: "local".into(),
            backend_url: String::new(),
            backend_model: String::new(),
            backend_api_key: String::new(),
            kv_type: e.kv_type,
            slots: e.slots,
            kv_cells: e.kv_cells,
            saved_mb: e.saved_bytes >> 20,
            flash_attn: e.flash_attn,
        }
    }
}

/// Everything the core tells the shell.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    /// Show `text` after the caret for `revision`, or hide when `text` is empty.
    #[serde(rename_all = "camelCase")]
    Suggestion {
        revision: u64,
        text: String,
        /// model | typeThrough | cache | pending | policy | dismissed | error | emoji | autocorrect | details
        source: &'static str,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ms: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        prefilled: Option<usize>,
        #[serde(skip_serializing_if = "Option::is_none")]
        stop: Option<&'static str>,
        /// Text just before the caret that accepting deletes first (emoji, autocorrect).
        #[serde(skip_serializing_if = "Option::is_none")]
        replace: Option<String>,
        /// What a replacement stands for, for display (`:tada:`, the misspelled word), or which
        /// of the user's details a `details` fill is (`email`, `name`, …).
        #[serde(skip_serializing_if = "Option::is_none")]
        label: Option<String>,
    },
    /// Engine lifecycle: loading | ready | idle (model unloaded) | paused | error.
    Status { state: &'static str, detail: String },
}

pub type EventSink = Box<dyn Fn(&Event) + Send + Sync>;

enum JobKind {
    Complete,
    Warm,
}

struct Job {
    kind: JobKind,
    revision: u64,
    field_key: u64,
    text_before: String,
    prompt: Prompt,
    queued: Instant,
    /// The snapshot the prompt came from (rebuilt for the prefetch).
    snapshot: Snapshot,
}

/// What the user typed in the focused field since it got focus, for the history.
struct FieldTrack {
    key: u64,
    app: String,
    start: String,
    last: String,
    accepted: bool,
}

/// Minimum typed characters for a field to be recorded (Cotypist skips short texts).
const MIN_RECORD_CHARS: usize = 20;

struct Shared {
    latest: AtomicU64,
    pending: Mutex<Option<Job>>,
    wake: Condvar,
    shutdown: AtomicBool,
    /// `settings.paused`, readable without the settings lock (the worker's cancel checks).
    paused: AtomicBool,
    session: Mutex<Session>,
    settings: RwLock<Settings>,
    compat: CompatDb,
    sink: EventSink,
    history: Mutex<History>,
    profile: Mutex<Profile>,
    /// Bumped whenever the profile changes; the engine re-derives its bias when it differs.
    profile_gen: AtomicU64,
    track: Mutex<Option<FieldTrack>>,
    /// Personal examples chosen once per field, so the prompt header stays stable.
    examples: Mutex<HashMap<u64, Vec<String>>>,
    /// The built-in engine is loaded: it can trim mid-line suggestions (set by the worker).
    mid_line_ok: AtomicBool,
    /// The shell's completer for the "shell" backend.
    completer: backend::CompleterSlot,
    /// The user's own details (`ft_engine_set_details`), for fills.
    details: RwLock<UserDetails>,
    /// The prompt header's writer line; empty unless the user allowed it.
    writer: RwLock<String>,
    /// Completions come from an HTTP server, which may not be on this Mac: the writer line
    /// and other apps' text are never sent there.
    remote_http: bool,
    /// Text from other apps' windows (`ft_engine_set_context`) and the current selection.
    others: Mutex<OtherApps>,
    /// The engine's context size in tokens: the prompt must leave 64 of it free.
    n_ctx: usize,
    /// The pool was emptied (pause, lock, sleep, the setting off): the engine drops every
    /// prompt and saved context holding other apps' text before its next request.
    forget: AtomicBool,
    /// The engine's cache after its last request or background step (measurements, logs).
    cache: Mutex<CacheStats>,
    /// Requests served with an older header while the new one prefilled (D47).
    served_old: AtomicU64,
}

fn debug() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("FORETYPE_DEBUG").is_some())
}

/// The engine handle a shell holds. Cheap to call from any thread; inference runs on an
/// internal worker thread and results arrive through the event sink.
pub struct Core {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
}

impl Core {
    pub fn new(config: CoreConfig, sink: EventSink) -> Self {
        let history = match history::parse_key(&config.history_key_hex) {
            Some(key) if !config.history_path.is_empty() => History::open(&config.history_path, &key),
            _ => History::in_memory(),
        };
        let profile = Profile::from_records(history.records());
        let shared = Arc::new(Shared {
            latest: AtomicU64::new(0),
            pending: Mutex::new(None),
            wake: Condvar::new(),
            shutdown: AtomicBool::new(false),
            paused: AtomicBool::new(config.settings.paused),
            session: Mutex::new(Session::default()),
            settings: RwLock::new(config.settings.clone()),
            compat: CompatDb::bundled(),
            sink,
            history: Mutex::new(history),
            profile: Mutex::new(profile),
            profile_gen: AtomicU64::new(1),
            track: Mutex::new(None),
            examples: Mutex::new(HashMap::new()),
            mid_line_ok: AtomicBool::new(false),
            completer: backend::CompleterSlot::default(),
            details: RwLock::new(UserDetails::default()),
            writer: RwLock::new(String::new()),
            remote_http: matches!(config.backend.as_str(), "llama-server" | "openai"),
            others: Mutex::new(OtherApps::default()),
            n_ctx: config.n_ctx as usize,
            forget: AtomicBool::new(false),
            cache: Mutex::new(CacheStats::default()),
            served_old: AtomicU64::new(0),
        });
        let engine_cfg = EngineConfig {
            model_path: config.model_path.clone(),
            n_ctx: config.n_ctx,
            n_gpu_layers: config.n_gpu_layers,
            n_threads: config.n_threads,
            kv_type: config.kv_type.clone(),
            slots: config.slots,
            kv_cells: config.kv_cells,
            saved_bytes: config.saved_mb << 20,
            flash_attn: config.flash_attn,
            ..EngineConfig::default()
        };
        let remote = (config.backend != "local" && !config.backend.is_empty()).then(|| RemoteConfig {
            kind: config.backend.clone(),
            url: config.backend_url.clone(),
            model: config.backend_model.clone(),
            api_key: config.backend_api_key.clone(),
        });
        let worker_shared = shared.clone();
        let worker = std::thread::Builder::new()
            .name("foretype.engine".into())
            .spawn(move || worker_loop(worker_shared, engine_cfg, remote))
            .expect("spawn engine thread");
        Self { shared, worker: Some(worker) }
    }

    /// Installs the shell's completer, used by the "shell" backend (Apple Foundation Models
    /// on macOS). It runs on the engine thread and may block.
    pub fn set_completer(&self, completer: backend::Completer) {
        *self.shared.completer.write().unwrap() = Some(completer);
    }

    pub fn configure(&self, settings: Settings) {
        let paused = settings.paused;
        *self.shared.settings.write().unwrap() = settings;
        self.shared.session.lock().unwrap().clear();
        self.shared.examples.lock().unwrap().clear();
        if self.shared.paused.swap(paused, Ordering::SeqCst) != paused {
            if paused {
                // Drop what is queued and cancel what is running (between decode steps).
                self.shared.pending.lock().unwrap().take();
                self.shared.latest.fetch_add(1, Ordering::SeqCst);
            }
            self.shared.wake.notify_all();
        }
    }

    pub fn is_paused(&self) -> bool {
        self.shared.paused.load(Ordering::SeqCst)
    }

    /// The user's own details: offered as fills when the text asks for one, and (when
    /// `in_prompt` is set and the backend is on this Mac) named in the prompt header.
    pub fn set_details(&self, details: UserDetails) {
        let writer = if details.in_prompt && !self.shared.remote_http { details.writer() } else { String::new() };
        if debug() {
            eprintln!("[foretype] details: {details:?}, writer line {}", if writer.is_empty() { "off" } else { "on" });
        }
        *self.shared.details.write().unwrap() = details;
        *self.shared.writer.write().unwrap() = writer;
        self.shared.session.lock().unwrap().clear();
    }

    /// Replaces the pool of other apps' text (D42). Ignored with a server backend: other
    /// apps' text only ever reaches an on-device model. An empty list clears it.
    pub fn set_context(&self, passages: Vec<Passage>) {
        let passages = if self.shared.remote_http { Vec::new() } else { passages };
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
        let mut o = self.shared.others.lock().unwrap();
        if passages.is_empty() && !(o.is_empty() && o.section().is_empty()) {
            // Forgotten means forgotten: the KV cache and saved contexts hold the old text.
            self.shared.forget.store(true, Ordering::SeqCst);
            self.shared.wake.notify_all();
        }
        o.set_passages(&passages, now);
        if debug() {
            let (w, c) = o.size();
            eprintln!("[foretype] other apps: {w} windows, {c} passages ({} visible)", passages.iter().filter(|p| p.visible).count());
        }
    }

    /// How often the other-apps section changed (each change costs a full prefill).
    pub fn context_changes(&self) -> u64 {
        self.shared.others.lock().unwrap().changes
    }

    /// The built-in engine's cache after its last request or background step.
    pub fn cache_stats(&self) -> CacheStats {
        self.shared.cache.lock().unwrap().clone()
    }

    /// Requests served with an older header while a new one prefilled (D47).
    pub fn served_old(&self) -> u64 {
        self.shared.served_old.load(Ordering::SeqCst)
    }

    /// (records, distinct words) in the personalization history.
    pub fn history_stats(&self) -> (usize, usize) {
        (self.shared.history.lock().unwrap().records().len(), self.shared.profile.lock().unwrap().word_count())
    }

    /// The history file is there but its key opens none of it (or it can't be read): it is
    /// kept as it is and nothing is recorded until it is cleared.
    pub fn history_locked(&self) -> bool {
        self.shared.history.lock().unwrap().is_locked()
    }

    /// Switches to the encrypted history file at `path` (personalization turned on at
    /// runtime). Returns false if the key is not 64 hex characters.
    pub fn open_history(&self, path: &str, key_hex: &str) -> bool {
        let Some(key) = history::parse_key(key_hex) else { return false };
        let h = History::open(path, &key);
        *self.shared.profile.lock().unwrap() = Profile::from_records(h.records());
        *self.shared.history.lock().unwrap() = h;
        self.shared.examples.lock().unwrap().clear();
        self.shared.profile_gen.fetch_add(1, Ordering::SeqCst);
        true
    }

    /// Deletes the writing history; the model is unbiased again from the next suggestion.
    pub fn clear_history(&self) -> Result<(), String> {
        self.shared.history.lock().unwrap().clear()?;
        *self.shared.profile.lock().unwrap() = Profile::new();
        *self.shared.track.lock().unwrap() = None;
        self.shared.examples.lock().unwrap().clear();
        self.shared.profile_gen.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    /// Adds earlier writing (e.g. imported from another app) as `(app, text)` pairs.
    pub fn import_history(&self, items: Vec<(String, String)>) -> Result<usize, String> {
        let mut n = 0;
        {
            let mut h = self.shared.history.lock().unwrap();
            let mut p = self.shared.profile.lock().unwrap();
            for (app, text) in items {
                if text.trim().chars().count() < MIN_RECORD_CHARS {
                    continue;
                }
                h.append(Record::now(&app, text.trim()))?;
                p.add_text(&text);
                n += 1;
            }
        }
        self.shared.examples.lock().unwrap().clear();
        self.shared.profile_gen.fetch_add(1, Ordering::SeqCst);
        Ok(n)
    }

    fn record(&self, t: &FieldTrack) {
        if !t.accepted {
            return;
        }
        let common = t.start.char_indices().zip(t.last.chars()).take_while(|((_, a), b)| a == b).count();
        let typed: String = t.last.chars().skip(common).collect();
        let typed = typed.trim();
        if typed.chars().count() < MIN_RECORD_CHARS {
            return;
        }
        if let Err(e) = self.shared.history.lock().unwrap().append(Record::now(&t.app, typed)) {
            eprintln!("[foretype] history append failed: {e}");
            return;
        }
        self.shared.profile.lock().unwrap().add_text(typed);
        self.shared.profile_gen.fetch_add(1, Ordering::SeqCst);
        if debug() {
            eprintln!("[foretype] recorded {} chars from {}", typed.chars().count(), t.app);
        }
    }

    /// Follows the focused field for the history: finishes a field when focus moves away or
    /// its text is cleared (a sent chat message), and starts tracking eligible fields.
    fn observe(&self, snap: &Snapshot, doc_text: &str, eligible: bool) {
        let mut track = self.shared.track.lock().unwrap();
        let finished = match track.as_ref() {
            Some(t) if t.key != snap.field_key => true,
            Some(t) => {
                let (now, before) = (doc_text.chars().count(), t.last.chars().count());
                before >= MIN_RECORD_CHARS && now < before / 2
            }
            None => false,
        };
        if finished {
            if let Some(t) = track.take() {
                self.record(&t);
            }
        }
        if !eligible {
            if track.as_ref().is_some_and(|t| t.key != snap.field_key) {
                *track = None;
            }
            return;
        }
        match track.as_mut() {
            Some(t) => t.last = doc_text.to_string(),
            None => {
                *track = Some(FieldTrack {
                    key: snap.field_key,
                    app: snap.bundle_id.clone(),
                    start: doc_text.to_string(),
                    last: doc_text.to_string(),
                    accepted: false,
                })
            }
        }
    }

    pub fn settings(&self) -> Settings {
        self.shared.settings.read().unwrap().clone()
    }

    pub fn compat_rule(&self, bundle_id: &str) -> policy::AppRule {
        self.shared.compat.rule(bundle_id)
    }

    fn emit_suggestion(&self, revision: u64, text: String, source: &'static str, reason: Option<String>) {
        (self.shared.sink)(&Event::Suggestion {
            revision,
            text,
            source,
            reason,
            ms: None,
            prefilled: None,
            stop: None,
            replace: None,
            label: None,
        });
    }

    /// Shows `text` in place of `replace` at the end of the text before the caret.
    fn emit_replacement(&self, snap: &Snapshot, replace: &str, text: &str, source: &'static str, label: String) {
        self.shared.session.lock().unwrap().set_replacement(snap.field_key, &snap.text_before, replace, text);
        (self.shared.sink)(&Event::Suggestion {
            revision: snap.revision,
            text: text.to_string(),
            source,
            reason: None,
            ms: None,
            prefilled: None,
            stop: None,
            replace: Some(replace.to_string()),
            label: Some(label),
        });
    }

    /// Offers one of the user's details. Not logged: the value is personal.
    fn emit_fill(&self, snap: &Snapshot, fill: details::Fill) {
        self.shared.session.lock().unwrap().set_fill(snap.field_key, &snap.text_before, &fill.replace, &fill.text, fill.field.whole());
        (self.shared.sink)(&Event::Suggestion {
            revision: snap.revision,
            text: fill.text,
            source: "details",
            reason: None,
            ms: None,
            prefilled: None,
            stop: None,
            replace: (!fill.replace.is_empty()).then_some(fill.replace),
            label: Some(fill.field.key().to_string()),
        });
    }

    /// Handles a field change. Returns synchronously for policy decisions and reused
    /// suggestions; otherwise queues inference (latest wins) and emits a `pending` hide.
    pub fn submit(&self, mut snap: Snapshot) {
        let rev = snap.revision;
        self.shared.latest.store(rev, Ordering::SeqCst);
        if self.is_paused() {
            return self.emit_suggestion(rev, String::new(), "policy", Some("paused".into()));
        }
        let settings = self.settings();
        if !settings.enabled {
            return self.emit_suggestion(rev, String::new(), "policy", Some("disabled".into()));
        }
        if !settings.only_apps.is_empty() && !settings.only_apps.contains(&snap.bundle_id) {
            return self.emit_suggestion(rev, String::new(), "policy", Some("notInOnlyApps".into()));
        }
        let disabled: HashSet<String> = settings.disabled_apps.iter().cloned().collect();
        let enabled: HashSet<String> = settings.enabled_apps.iter().cloned().collect();
        let mid_line = settings.mid_line && self.shared.mid_line_ok.load(Ordering::SeqCst);
        if let Some(reason) = policy::evaluate(&snap, &self.shared.compat, &disabled, &enabled, mid_line) {
            self.shared.session.lock().unwrap().clear();
            if settings.personalize {
                self.observe(&snap, &snap.text_before, false);
            }
            return self.emit_suggestion(rev, String::new(), "policy", Some(reason.into()));
        }
        // In a terminal only the agent prompt's own text is the document; the scrollback
        // above it reaches the model as screen context instead.
        if self.shared.compat.rule(&snap.bundle_id).agent_prompt_only && !enabled.contains(&snap.bundle_id) {
            if let Some(prompt) = self.shared.compat.agent_prompt_text(&snap.text_before) {
                snap.text_before = prompt.to_string();
            }
        }
        if settings.personalize {
            self.observe(&snap, &snap.text_before, true);
        }
        {
            let mut session = self.shared.session.lock().unwrap();
            if !snap.force && session.is_dismissed(snap.field_key, &snap.text_before) {
                return self.emit_suggestion(rev, String::new(), "dismissed", None);
            }
            drop(session);
            // Before type-through: a model that continues a misspelling ("recie" → "ve the")
            // must not carry the user past the typo gate and autocorrect.
            if let Some(handled) = self.typing_aids(&snap, &settings) {
                return handled;
            }
            let mut session = self.shared.session.lock().unwrap();
            if let Some(rest) = session.type_through(snap.field_key, &snap.text_before) {
                drop(session);
                return self.emit_suggestion(rev, rest, "typeThrough", None);
            }
            let hit = if line_suffix(&snap).is_empty() { session.cached(snap.field_key, &snap.text_before) } else { None };
            if let Some(hit) = hit {
                session.set(snap.field_key, &snap.text_before, &hit);
                drop(session);
                return self.emit_suggestion(rev, hit, "cache", None);
            }
            session.clear();
        }
        let examples = self.examples_for(&snap, &settings);
        let prompt = build_prompt(&self.shared, &snap, &settings, &examples, true);
        self.enqueue(Job {
            kind: JobKind::Complete,
            revision: rev,
            field_key: snap.field_key,
            text_before: snap.text_before.clone(),
            prompt,
            queued: Instant::now(),
            snapshot: snap,
        });
        self.emit_suggestion(rev, String::new(), "pending", None);
    }

    /// The user's details, emoji shortcodes, autocorrect and the typo gate, which answer
    /// without the model. `Some(())` means an event was emitted.
    fn typing_aids(&self, snap: &Snapshot, settings: &Settings) -> Option<()> {
        // First: a detail being typed ("priya.ra") is no typo, and its value is exact.
        if line_suffix(snap).is_empty() {
            let fill = details::fill(&snap.text_before, &self.shared.details.read().unwrap());
            if let Some(fill) = fill {
                self.emit_fill(snap, fill);
                return Some(());
            }
        }
        if settings.emoji {
            if let Some(typed) = emoji::typed_shortcode(&snap.text_before) {
                match emoji::lookup(&typed[1..]) {
                    Some((name, e)) => self.emit_replacement(snap, typed, e, "emoji", format!(":{name}:")),
                    // A shortcode with no match: the model has nothing useful to add either.
                    None => self.emit_suggestion(snap.revision, String::new(), "policy", Some("shortcode".into())),
                }
                return Some(());
            }
        }
        if settings.autocorrect {
            if let Some((replace, text)) = self.correction(snap) {
                self.emit_replacement(snap, &replace, &text, "autocorrect", snap.spell_word.clone());
                return Some(());
            }
        }
        if settings.typo_gate && snap.spell_fragment == "typo" && !snap.force {
            let (before, fragment) = words::split_fragment(&snap.text_before);
            if !self.plausible_word(words::fragment_word(fragment), before) {
                self.emit_suggestion(snap.revision, String::new(), "policy", Some("typo".into()));
                return Some(());
            }
        }
        None
    }

    /// A fragment the spell checker doesn't know may still be a real word: names and
    /// brands (capitalized), acronyms and codes (digits, all caps), very short fragments,
    /// romanized Hindi, a word typed earlier in the field (`before`), and the user's own
    /// vocabulary.
    fn plausible_word(&self, w: &str, before: &str) -> bool {
        let mut chars = w.chars();
        let Some(first) = chars.next() else { return true };
        if w.chars().count() < 3 || first.is_uppercase() || w.chars().any(|c| c.is_ascii_digit()) {
            return true;
        }
        let lower = w.to_lowercase();
        hinglish::has_prefix(&lower)
            || hinglish::in_context(before)
            || words::has_word(before, &lower, true)
            || self.shared.profile.lock().unwrap().has_prefix(&lower)
    }

    /// `(replace, insert)` for the misspelled word just finished, when it should be fixed:
    /// not a name in mid-sentence, not an acronym or code, not romanized Hindi or a word in
    /// Hinglish text, not a word kept earlier in the field, not one of the user's own words.
    fn correction(&self, snap: &Snapshot) -> Option<(String, String)> {
        let (word, fix) = (snap.spell_word.as_str(), snap.spell_correction.as_str());
        if word.is_empty() || fix.is_empty() || word == fix {
            return None;
        }
        let trimmed = snap.text_before.trim_end_matches(' ');
        let spaces = &snap.text_before[trimmed.len()..];
        if spaces.is_empty() || spaces.len() > 2 || !trimmed.ends_with(word) {
            return None;
        }
        let pre = &trimmed[..trimmed.len() - word.len()];
        if pre.chars().next_back().is_some_and(words::is_word_char) {
            return None; // `word` is the tail of a longer word
        }
        let before = pre.trim_end();
        let sentence_start = before.is_empty() || words::ends_sentence(before) || pre.trim_end_matches([' ', '\t']).ends_with('\n');
        let capitalized = word.chars().next().is_some_and(char::is_uppercase);
        let lower = word.to_lowercase();
        if (capitalized && !sentence_start)
            || word.chars().any(|c| c.is_ascii_digit())
            || word.chars().filter(|c| c.is_alphabetic()).all(char::is_uppercase)
            || hinglish::is_word(&lower)
            || hinglish::in_context(before)
            || words::has_word(before, &lower, false)
            || self.shared.profile.lock().unwrap().knows(&lower)
        {
            return None;
        }
        Some((format!("{word}{spaces}"), format!("{fix}{spaces}")))
    }

    /// Prefills the context for a newly focused field so the first suggestion is fast.
    /// Never displaces a queued completion.
    pub fn warm(&self, snap: Snapshot) {
        if self.is_paused() {
            return;
        }
        let settings = self.settings();
        let examples = self.examples_for(&snap, &settings);
        let prompt = build_prompt(&self.shared, &snap, &settings, &examples, true);
        let mut pending = self.shared.pending.lock().unwrap();
        if pending.is_none() && !self.is_paused() {
            *pending = Some(Job {
                kind: JobKind::Warm,
                revision: snap.revision,
                field_key: snap.field_key,
                text_before: snap.text_before.clone(),
                prompt,
                queued: Instant::now(),
                snapshot: snap,
            });
            self.shared.wake.notify_one();
        }
    }

    fn enqueue(&self, job: Job) {
        let mut pending = self.shared.pending.lock().unwrap();
        // Paused between the check in `submit` and here: nothing may wake the model.
        if self.is_paused() {
            return;
        }
        *pending = Some(job);
        self.shared.wake.notify_one();
    }

    /// Earlier writing from the same app for the prompt header, chosen on the field's first
    /// prompt and then kept, so the header (and the KV cache) stays stable while typing.
    fn examples_for(&self, snap: &Snapshot, settings: &Settings) -> Vec<String> {
        if !settings.personalize || !settings.personal_examples || snap.field_key == 0 {
            return Vec::new();
        }
        let mut cache = self.shared.examples.lock().unwrap();
        if let Some(e) = cache.get(&snap.field_key) {
            return e.clone();
        }
        let ex = profile::examples(self.shared.history.lock().unwrap().records(), &snap.bundle_id, &snap.text_before, 2, 280);
        if cache.len() > 64 {
            cache.clear();
        }
        cache.insert(snap.field_key, ex.clone());
        ex
    }

    /// What Tab (next word) or accept-all inserts, and what it replaces.
    pub fn accept(&self, mode: AcceptMode) -> Option<Accepted> {
        let r = self.shared.session.lock().unwrap().accept(mode);
        if r.is_some() {
            if let Some(t) = self.shared.track.lock().unwrap().as_mut() {
                t.accepted = true;
            }
        }
        r
    }

    /// Hides the suggestion and suppresses new ones until the text changes.
    pub fn dismiss(&self, field_key: u64, text_before: &str) {
        self.shared.latest.fetch_add(1, Ordering::SeqCst);
        self.shared.session.lock().unwrap().dismiss(field_key, text_before);
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        if let Some(t) = self.shared.track.lock().unwrap().take() {
            self.record(&t);
        }
        self.shared.shutdown.store(true, Ordering::SeqCst);
        self.shared.latest.fetch_add(1, Ordering::SeqCst);
        self.shared.wake.notify_all();
        if let Some(w) = self.worker.take() {
            let _ = w.join();
        }
    }
}

/// The rest of the caret's line when the caret is mid-line (more than spaces follow it).
fn line_suffix(snap: &Snapshot) -> &str {
    let line = snap.text_after.split('\n').next().unwrap_or("");
    if line.trim().is_empty() {
        ""
    } else {
        line
    }
}

/// Most of the line after the caret a mid-line prompt carries.
const MAX_SUFFIX_CHARS: usize = 200;

/// Tokens kept free for the body when sizing the other-apps section: `max_body_chars` bytes
/// at three bytes a token (Devanagari is three bytes and about one Qwen3 token a character;
/// English runs 4–4.5 characters a token), so the section doesn't shrink as the text grows.
fn body_reserve(max_body_chars: usize) -> usize {
    max_body_chars.div_ceil(3)
}

/// The prompt for a snapshot. `select`: pick the other-apps passages for this text (submit
/// and warm); otherwise the current section is reused (the prefetch, which must not move
/// the selection the next keystroke's prompt starts from).
fn build_prompt(shared: &Shared, snap: &Snapshot, settings: &Settings, examples: &[String], select: bool) -> Prompt {
    let instructions = settings.instructions_for(&snap.bundle_id);
    let writer = shared.writer.read().unwrap().clone();
    let mut input = ContextInput {
        other_apps: "",
        app_name: &snap.app_name,
        window_title: &snap.window_title,
        url: &snap.url,
        instructions: &instructions,
        writer: &writer,
        screen_context: &snap.screen_context,
        examples,
        text_before: &snap.text_before,
    };
    let section = other_apps_section(shared, snap, settings, &input, select);
    input.other_apps = &section;
    let mut prompt = context::build(&input, settings.max_body_chars);
    if settings.mid_line {
        prompt.suffix = line_suffix(snap).chars().take(MAX_SUFFIX_CHARS).collect();
    }
    prompt
}

/// The other-apps section for this prompt: its budget is the setting's, cut to what the
/// context has left after the rest of the header, the body's reserve and 64 tokens.
fn other_apps_section(shared: &Shared, snap: &Snapshot, settings: &Settings, input: &ContextInput, select: bool) -> String {
    let mut o = shared.others.lock().unwrap();
    if o.is_empty() && o.section().is_empty() {
        return String::new();
    }
    if !select {
        return o.section().to_string();
    }
    let rest = others::estimate_tokens(&context::header(input)) + body_reserve(settings.max_body_chars) + 64;
    let budget = settings.other_apps_tokens.min(shared.n_ctx.saturating_sub(rest));
    let body = context::body_window(&snap.text_before, settings.max_body_chars);
    let (committed, _) = words::split_fragment(body);
    let query = Query::new(committed, &snap.screen_context, &snap.window_title);
    let before = o.changes;
    let section = o.select(&query, budget).to_string();
    if debug() && o.changes != before {
        let d = shared.details.read().unwrap();
        eprintln!(
            "[foretype] other apps section: ~{} tokens (budget {budget}): {}",
            others::estimate_tokens(&section),
            d.redact(&o.describe())
        );
    }
    section
}

/// A prompt whose other-apps section didn't fit the context: the same prompt without it.
fn without_others(p: &Prompt) -> Option<Prompt> {
    p.without_others()
}

struct RemoteConfig {
    kind: String,
    url: String,
    model: String,
    api_key: String,
}

/// Where completions come from: the in-process engine or a user-supplied server.
enum Runner {
    Local(Engine),
    Remote(backend::HttpBackend),
}

impl Runner {
    fn complete(&mut self, prompt: &Prompt, opts: &GenOptions, cancel: &dyn Fn() -> bool) -> Result<engine::Completion, GenError> {
        match self {
            Runner::Local(e) => e.complete(prompt, opts, cancel),
            Runner::Remote(b) => b.complete(prompt, opts, cancel),
        }
    }

    fn set_vocabulary(&mut self, words: &[(String, f32)]) {
        match self {
            Runner::Local(e) => e.set_vocabulary(words),
            Runner::Remote(b) => b.set_vocabulary(words),
        }
    }

    fn is_local(&self) -> bool {
        matches!(self, Runner::Local(_))
    }
}

/// Tokens a request may prefill before it is served with the serving slot's older header
/// instead, while its own prefills in the background (D47): a keystroke's worth.
const FAST_PREFILL: usize = 48;

/// Milliseconds of background prefill between checks for a new request (D47): what a
/// keystroke arriving meanwhile can wait at most. Longer once the user has stopped for a
/// second (bigger pieces prefill faster: `--chunk-bench`).
const BACKGROUND_STEP_MS: f64 = 40.0;
const BACKGROUND_IDLE_STEP_MS: f64 = 120.0;

/// What a completion request runs on (D47): its own prompt when a slot holds it or nearly,
/// otherwise the prompt with the header of `live` (what the serving slot holds, for field
/// `live.0`; `context::with_old_header`), when that is cheaper and every passage of its
/// other-apps section is still in the pool; the request's own prompt then goes to the
/// background. Returns the prompt to serve, its tokens, and the tokens to prefill in the
/// background.
fn plan(e: &Engine, shared: &Shared, field: u64, target: &Prompt, live: Option<&(u64, Prompt)>) -> (Prompt, Vec<engine::Token>, Option<Vec<engine::Token>>) {
    let mut target = target.clone();
    let mut tokens = e.tokenize(&target.prefix);
    if tokens.len() + 64 > shared.n_ctx {
        if let Some(p) = target.without_others() {
            target = p;
            tokens = e.tokenize(&target.prefix);
        }
    }
    let cost = e.cost(&tokens);
    if e.slot_count() < 2 || cost <= FAST_PREFILL {
        return (target, tokens, None);
    }
    let old = live
        .filter(|(_, l)| shared.others.lock().unwrap().section_alive(l.others_section()))
        .and_then(|(f, l)| context::with_old_header(l, &target, *f == field));
    if let Some(old) = old {
        let old_tokens = e.tokenize(&old.prefix);
        if old_tokens.len() + 64 <= shared.n_ctx && e.cost(&old_tokens) < cost {
            return (old, old_tokens, Some(tokens));
        }
    }
    (target, tokens, None)
}

fn worker_loop(shared: Arc<Shared>, cfg: EngineConfig, remote: Option<RemoteConfig>) {
    let load = |shared: &Shared| -> Option<Runner> {
        if let Some(r) = &remote {
            return match backend::HttpBackend::with_completer(&r.kind, &r.url, &r.model, &r.api_key, shared.completer.clone()) {
                Ok(b) => {
                    (shared.sink)(&Event::Status { state: "ready", detail: b.describe() });
                    Some(Runner::Remote(b))
                }
                Err(err) => {
                    (shared.sink)(&Event::Status { state: "error", detail: err });
                    None
                }
            };
        }
        (shared.sink)(&Event::Status { state: "loading", detail: cfg.model_path.clone() });
        let t = Instant::now();
        match Engine::load(&cfg) {
            Ok(e) => {
                shared.mid_line_ok.store(true, Ordering::SeqCst);
                (shared.sink)(&Event::Status {
                    state: "ready",
                    detail: format!("loaded in {:.0} ms", t.elapsed().as_secs_f64() * 1000.0),
                });
                Some(Runner::Local(e))
            }
            Err(err) => {
                (shared.sink)(&Event::Status { state: "error", detail: err });
                None
            }
        }
    };
    // Started paused (the app opened while paused): nothing loads until the pause ends.
    let mut engine_slot = None;
    if !shared.paused.load(Ordering::SeqCst) {
        engine_slot = Some(match load(&shared) {
            Some(first) => first,
            None => return,
        });
    }
    let mut last_used = Instant::now();
    let mut applied_gen = 0u64;
    let mut paused = false;
    // The prompt the serving slot holds (and its field), and whether a new header waits to
    // be prefilled.
    let mut live: Option<(u64, Prompt)> = None;
    let mut background = false;
    let mut last_request = Instant::now();
    let publish = |e: &Engine| *shared.cache.lock().unwrap() = e.stats();

    loop {
        let job = {
            let mut pending = shared.pending.lock().unwrap();
            loop {
                if shared.shutdown.load(Ordering::SeqCst) {
                    return;
                }
                if shared.paused.load(Ordering::SeqCst) {
                    pending.take();
                    if !paused {
                        // Free the model (or the server client) now, not after the idle timeout.
                        drop(pending);
                        let was_local = engine_slot.as_ref().is_some_and(Runner::is_local);
                        engine_slot = None;
                        applied_gen = 0;
                        live = None;
                        background = false;
                        paused = true;
                        let detail = if was_local { "model unloaded" } else { "" };
                        (shared.sink)(&Event::Status { state: "paused", detail: detail.into() });
                        pending = shared.pending.lock().unwrap();
                        continue;
                    }
                    pending = shared.wake.wait_timeout(pending, Duration::from_secs(3600)).unwrap().0;
                    continue;
                }
                if paused {
                    // Resumed. A server client is cheap: back at once. The model loads on the
                    // first job, as after an idle unload.
                    paused = false;
                    last_used = Instant::now();
                    drop(pending);
                    if remote.is_some() {
                        engine_slot = load(&shared);
                        if engine_slot.is_none() {
                            return;
                        }
                    } else {
                        (shared.sink)(&Event::Status { state: "idle", detail: "model unloaded".into() });
                    }
                    pending = shared.pending.lock().unwrap();
                    continue;
                }
                if shared.forget.swap(false, Ordering::SeqCst) {
                    // Other apps' text was forgotten: so are the prompts holding it.
                    if let Some(Runner::Local(e)) = engine_slot.as_mut() {
                        e.reset();
                        publish(e);
                    }
                    live = None;
                    background = false;
                    if debug() {
                        eprintln!("[foretype] other apps' text forgotten: KV cache and saved contexts cleared");
                    }
                }
                if let Some(job) = pending.take() {
                    break job;
                }
                // Between requests: the next piece of a new header (D47).
                if background {
                    if let Some(Runner::Local(e)) = engine_slot.as_mut() {
                        drop(pending);
                        let busy = || {
                            shared.shutdown.load(Ordering::SeqCst)
                                || shared.paused.load(Ordering::SeqCst)
                                || shared.pending.lock().map(|p| p.is_some()).unwrap_or(true)
                        };
                        let step_ms = if last_request.elapsed() < Duration::from_secs(1) { BACKGROUND_STEP_MS } else { BACKGROUND_IDLE_STEP_MS };
                        let step = e.background_step(step_ms, &busy);
                        background = matches!(step, Background::Working(_));
                        publish(e);
                        if debug() && !background {
                            eprintln!("[foretype] background prefill: {step:?}, cache {:?}", e.stats());
                        }
                        last_used = Instant::now();
                        pending = shared.pending.lock().unwrap();
                        continue;
                    }
                    background = false;
                }
                // Idle: free the model's memory (Cotypist does the same) until needed again.
                let unload_after = shared.settings.read().unwrap().unload_after_s;
                let local = engine_slot.as_ref().is_some_and(Runner::is_local);
                if local && unload_after > 0 && last_used.elapsed() >= Duration::from_secs(unload_after) {
                    drop(pending);
                    engine_slot = None;
                    applied_gen = 0;
                    live = None;
                    *shared.cache.lock().unwrap() = CacheStats::default();
                    (shared.sink)(&Event::Status { state: "idle", detail: "model unloaded".into() });
                    pending = shared.pending.lock().unwrap();
                    continue;
                }
                let timeout = if local && unload_after > 0 {
                    Duration::from_secs(unload_after).saturating_sub(last_used.elapsed()).max(Duration::from_millis(50))
                } else {
                    Duration::from_secs(3600)
                };
                pending = shared.wake.wait_timeout(pending, timeout).unwrap().0;
            }
        };
        last_used = Instant::now();
        last_request = last_used;
        if shared.paused.load(Ordering::SeqCst) {
            continue;
        }
        if engine_slot.is_none() {
            engine_slot = load(&shared);
            if engine_slot.is_none() {
                return;
            }
        }
        let engine = engine_slot.as_mut().unwrap();
        let gen = shared.profile_gen.load(Ordering::SeqCst);
        if gen != applied_gen && shared.settings.read().unwrap().personalize {
            let words = shared.profile.lock().unwrap().weighted_words(3000, 2);
            engine.set_vocabulary(&words);
            applied_gen = gen;
        }
        let rev = job.revision;
        let latest = &shared.latest;
        let cancel = || latest.load(Ordering::SeqCst) != rev;
        match job.kind {
            JobKind::Warm => match engine {
                Runner::Local(e) => {
                    // A new field or header: prefilled between requests, never in their way.
                    let mut p = job.prompt;
                    let mut tokens = e.tokenize(&p.prefix);
                    if tokens.len() + 64 > shared.n_ctx {
                        if let Some(q) = without_others(&p) {
                            p = q;
                            tokens = e.tokenize(&p.prefix);
                        }
                    }
                    let cost = e.cost(&tokens);
                    if cost > 1 {
                        e.set_background(tokens);
                        background = true;
                    }
                    if debug() {
                        eprintln!("[foretype] warm rev={rev}: {cost} tokens to prefill in the background");
                    }
                }
                Runner::Remote(b) => {
                    let mut r = b.warm(&job.prompt.prefix);
                    if let (Err(GenError::TooLong(_)), Some(p)) = (&r, without_others(&job.prompt)) {
                        r = b.warm(&p.prefix);
                    }
                    if debug() {
                        eprintln!("[foretype] warm rev={rev} -> {r:?}");
                    }
                }
            },
            JobKind::Complete => {
                if cancel() {
                    continue;
                }
                let settings = shared.settings.read().unwrap().clone();
                // On battery, wait briefly for the next keystroke mid-word; word boundaries
                // (space, punctuation, newline) still fire at once.
                if settings.debounce_ms > 0 && !job.prompt.fragment.trim().is_empty() {
                    let until = Instant::now() + Duration::from_millis(settings.debounce_ms);
                    while Instant::now() < until && !cancel() {
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    if cancel() {
                        continue;
                    }
                }
                let mid_line = !job.prompt.suffix.is_empty();
                let opts = GenOptions {
                    max_words: if mid_line { settings.length_words.clamp(1, 3) } else { settings.length_words.max(1) },
                    deadline: Duration::from_millis(settings.deadline_ms),
                    stop_at_sentence_end: settings.stop_at_sentence_end,
                    personal_strength: settings.personal_strength(),
                    beam_width: settings.beam_width,
                };
                // The prompt actually served: the request's own, or (D47) the same with the
                // serving slot's older header while the new one prefills in the background.
                let mut served = job.prompt.clone();
                let mut result = match engine {
                    Runner::Local(e) => {
                        let (p, tokens, later) = plan(e, &shared, job.field_key, &job.prompt, live.as_ref());
                        let old_header = later.is_some();
                        background = old_header;
                        match later {
                            Some(t) => e.set_background(t),
                            None => e.finish_background(),
                        }
                        if old_header {
                            shared.served_old.fetch_add(1, Ordering::SeqCst);
                            if debug() {
                                eprintln!("[foretype] rev={rev} served with the previous header; the new one prefills in the background");
                            }
                        }
                        served = p;
                        let r = e.complete_tokens(&tokens, &served, &opts, &cancel);
                        live = Some((job.field_key, served.clone()));
                        publish(e);
                        r
                    }
                    Runner::Remote(b) => b.complete(&served, &opts, &cancel),
                };
                // Too long for the context: the other apps' text is what goes first (D42).
                if let (Err(GenError::TooLong(n)), Some(p)) = (&result, without_others(&served)) {
                    if debug() {
                        eprintln!("[foretype] rev={rev} prompt of {n} tokens too long: other apps' text left out");
                    }
                    served = p;
                    result = engine.complete(&served, &opts, &cancel);
                    if engine.is_local() {
                        live = Some((job.field_key, served.clone()));
                    }
                }
                match result {
                    Ok(mut c) => {
                        c.text = context::strip_marker_echo(&c.text).to_string();
                        let queue_ms = job.queued.elapsed().as_secs_f64() * 1000.0;
                        if debug() {
                            eprintln!(
                                "[foretype] rev={rev} prefill={} tok/{:.1}ms gen={} total={:.1}ms queue+total={queue_ms:.1}ms stop={} {:?}",
                                c.prefilled_tokens,
                                c.prefill_ms,
                                c.generated_tokens,
                                c.total_ms,
                                c.stop,
                                shared.details.read().unwrap().redact(&c.text)
                            );
                        }
                        if cancel() {
                            continue;
                        }
                        if mid_line {
                            shared.session.lock().unwrap().set_uncached(job.field_key, &job.text_before, &c.text);
                        } else {
                            shared.session.lock().unwrap().set(job.field_key, &job.text_before, &c.text);
                        }
                        let shown = c.text.clone();
                        (shared.sink)(&Event::Suggestion {
                            revision: rev,
                            text: c.text,
                            source: "model",
                            reason: None,
                            ms: Some(queue_ms),
                            prefilled: Some(c.prefilled_tokens),
                            stop: Some(c.stop),
                            replace: None,
                            label: None,
                        });
                        // Prefetch what follows the suggestion while the user reads it; any new
                        // request cancels this between decode steps. It keeps the header the
                        // suggestion was served with. Not while a new header waits: the time
                        // between keystrokes goes to prefilling it (D47).
                        if settings.prefetch && !mid_line && !shown.trim().is_empty() && !background {
                            let mut next = job.snapshot.clone();
                            next.text_before = format!("{}{}", job.text_before, shown);
                            let examples = shared.examples.lock().unwrap().get(&job.field_key).cloned().unwrap_or_default();
                            let mut prompt = build_prompt(&shared, &next, &settings, &examples, false);
                            if served.prefix[..served.header] != job.prompt.prefix[..job.prompt.header] {
                                prompt = prompt.with_header_of(&served);
                            }
                            let busy = || {
                                shared.shutdown.load(Ordering::SeqCst)
                                    || shared.paused.load(Ordering::SeqCst)
                                    || shared.pending.lock().map(|p| p.is_some()).unwrap_or(true)
                            };
                            if !busy() {
                                if let Ok(mut p) = engine.complete(&prompt, &opts, &busy) {
                                    p.text = context::strip_marker_echo(&p.text).to_string();
                                    if !p.text.trim().is_empty() {
                                        shared.session.lock().unwrap().remember(job.field_key, &next.text_before, &p.text);
                                        if debug() {
                                            let d = shared.details.read().unwrap();
                                            eprintln!("[foretype] prefetched {:?} after {:?}", d.redact(&p.text), d.redact(&shown));
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Err(GenError::Cancelled) => {}
                    Err(e @ (GenError::Failed(_) | GenError::TooLong(_))) => {
                        let reason = match e {
                            GenError::TooLong(n) => format!("prompt of {n} tokens exceeds context"),
                            GenError::Failed(e) => e,
                            GenError::Cancelled => unreachable!(),
                        };
                        (shared.sink)(&Event::Suggestion {
                            revision: rev,
                            text: String::new(),
                            source: "error",
                            reason: Some(reason),
                            ms: None,
                            prefilled: None,
                            stop: None,
                            replace: None,
                            label: None,
                        });
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn core() -> Core {
        // No model: the engine thread reports an error and exits; the policy, session and
        // history paths still run on the caller's thread.
        let core = Core::new(CoreConfig { model_path: "/nonexistent.gguf".into(), ..CoreConfig::default() }, Box::new(|_| {}));
        core.configure(Settings { personalize: true, ..Settings::default() });
        core
    }

    fn snap(key: u64, text: &str) -> Snapshot {
        Snapshot { field_key: key, bundle_id: "com.apple.mail".into(), role: "AXTextArea".into(), text_before: text.into(), ..Snapshot::default() }
    }

    fn accept_here(c: &Core) {
        c.shared.track.lock().unwrap().as_mut().unwrap().accepted = true;
    }

    #[test]
    fn records_typed_text_on_focus_change_only_after_an_accept() {
        let c = core();
        c.submit(snap(1, "Quoted thread above."));
        c.submit(snap(1, "Quoted thread above. Thanks Priya, I will send the timeline"));
        c.submit(snap(2, "Other field"));
        assert_eq!(c.history_stats().0, 0, "no accept, nothing recorded");

        c.submit(snap(3, "Re: planning."));
        accept_here(&c);
        c.submit(snap(3, "Re: planning. Thanks Priya, I will send the timeline before Thursday."));
        c.submit(snap(4, "elsewhere"));
        let h = c.shared.history.lock().unwrap();
        assert_eq!(h.records().len(), 1);
        assert_eq!(h.records()[0].text, "Thanks Priya, I will send the timeline before Thursday.");
        assert_eq!(h.records()[0].app, "com.apple.mail");
    }

    #[test]
    fn records_a_sent_chat_message_when_the_field_clears() {
        let c = core();
        c.submit(snap(7, "Hi"));
        accept_here(&c);
        c.submit(snap(7, "Hi team, the deployment finished without errors"));
        c.submit(snap(7, ""));
        assert_eq!(c.shared.history.lock().unwrap().records()[0].text, "team, the deployment finished without errors");
        // Short texts are skipped.
        c.submit(snap(7, "ok"));
        accept_here(&c);
        c.submit(snap(7, "ok thanks"));
        c.submit(snap(8, ""));
        assert_eq!(c.history_stats().0, 1);
    }

    #[test]
    fn a_history_its_key_cant_open_stays_as_it_is() {
        let path = std::env::temp_dir().join(format!("foretype-test-{}-core-locked.bin", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let mut h = History::open(&path, &[1u8; 32]);
        h.append(Record::now("com.apple.mail", "Written under the key that was lost.")).unwrap();
        let before = std::fs::read(&path).unwrap();

        let c = Core::new(
            CoreConfig {
                model_path: "/nonexistent.gguf".into(),
                history_path: path.to_string_lossy().into(),
                history_key_hex: "02".repeat(32),
                ..CoreConfig::default()
            },
            Box::new(|_| {}),
        );
        c.configure(Settings { personalize: true, ..Settings::default() });
        assert!(c.history_locked());
        assert!(c.import_history(vec![("".into(), "An imported paragraph that is long enough.".into())]).is_err());
        c.submit(snap(1, "Re:"));
        accept_here(&c);
        c.submit(snap(1, "Re: a reply typed while the history is locked."));
        c.submit(snap(2, ""));
        assert_eq!(c.history_stats(), (0, 0), "nothing recorded or learned");
        assert_eq!(std::fs::read(&path).unwrap(), before);

        c.clear_history().unwrap();
        assert!(!c.history_locked());
        assert!(!path.exists());
        c.import_history(vec![("".into(), "A paragraph for the new history file.".into())]).unwrap();
        assert_eq!(c.history_stats().0, 1);
        let _ = std::fs::remove_file(&path);
    }

    fn core_with_events() -> (Core, std::sync::mpsc::Receiver<Event>) {
        let (tx, rx) = std::sync::mpsc::channel();
        let tx = Mutex::new(tx);
        let core = Core::new(
            CoreConfig { model_path: "/nonexistent.gguf".into(), ..CoreConfig::default() },
            Box::new(move |e| {
                let _ = tx.lock().unwrap().send(e.clone());
            }),
        );
        (core, rx)
    }

    /// The suggestion event for `rev`, skipping status events.
    fn suggestion_for(rx: &std::sync::mpsc::Receiver<Event>, rev: u64) -> (String, &'static str, Option<String>, Option<String>) {
        loop {
            match rx.recv_timeout(Duration::from_secs(2)).expect("event") {
                Event::Suggestion { revision, text, source, reason, replace, .. } if revision == rev => {
                    return (text, source, replace, reason)
                }
                _ => {}
            }
        }
    }

    #[test]
    fn emoji_shortcode_becomes_a_replacement() {
        let (c, rx) = core_with_events();
        c.submit(Snapshot { revision: 1, ..snap(1, "Great news :ta") });
        let (text, source, replace, _) = suggestion_for(&rx, 1);
        assert_eq!((text.as_str(), source, replace.as_deref()), ("\u{1F389}", "emoji", Some(":ta")));
        let a = c.accept(AcceptMode::NextWord).unwrap();
        assert_eq!((a.insert.as_str(), a.replace.as_str()), ("\u{1F389}", ":ta"));
        c.submit(Snapshot { revision: 2, ..snap(1, "Great news :zzqqx") });
        assert_eq!(suggestion_for(&rx, 2).3.as_deref(), Some("shortcode"));
    }

    #[test]
    fn autocorrect_replaces_the_finished_word() {
        let (c, rx) = core_with_events();
        let fix = |rev, text: &str, word: &str, correction: &str| Snapshot {
            revision: rev,
            spell_word: word.into(),
            spell_correction: correction.into(),
            ..snap(1, text)
        };
        c.submit(fix(1, "I will recieve ", "recieve", "receive"));
        let (text, source, replace, _) = suggestion_for(&rx, 1);
        assert_eq!((text.as_str(), source, replace.as_deref()), ("receive ", "autocorrect", Some("recieve ")));
        c.submit(fix(2, "Teh ", "Teh", "The"));
        assert_eq!(suggestion_for(&rx, 2).1, "autocorrect", "capitalized at a sentence start");
        c.submit(fix(3, "Hello.\nTeh ", "Teh", "The"));
        assert_eq!(suggestion_for(&rx, 3).1, "autocorrect", "capitalized after a newline");
        c.submit(fix(4, "I met Priyaa ", "Priyaa", "Priya"));
        assert_ne!(suggestion_for(&rx, 4).1, "autocorrect", "a name in mid-sentence");
        c.submit(fix(5, "see the NASAA ", "NASAA", "NASA"));
        assert_ne!(suggestion_for(&rx, 5).1, "autocorrect", "all caps");
        c.submit(fix(6, "I will recieve", "recieve", "receive"));
        assert_ne!(suggestion_for(&rx, 6).1, "autocorrect", "no space yet: still typing");
        c.submit(fix(7, "ठीक है। Teh ", "Teh", "The"));
        assert_eq!(suggestion_for(&rx, 7).1, "autocorrect", "capitalized after a danda");
        c.configure(Settings { autocorrect: false, ..Settings::default() });
        c.submit(fix(8, "I will recieve ", "recieve", "receive"));
        assert_ne!(suggestion_for(&rx, 8).1, "autocorrect", "turned off");
    }

    #[test]
    fn typing_aids_come_before_type_through() {
        let (c, rx) = core_with_events();
        // A suggestion that continues a misspelling is showing...
        c.shared.session.lock().unwrap().set(1, "I will rec", "ieve the notes");
        // ...the user types through it to the end of the word and a space.
        c.submit(Snapshot {
            revision: 1,
            spell_word: "recieve".into(),
            spell_correction: "receive".into(),
            ..snap(1, "I will recieve ")
        });
        assert_eq!(suggestion_for(&rx, 1).1, "autocorrect");
        c.shared.session.lock().unwrap().set(1, "I will rec", "ieve the notes");
        c.submit(Snapshot { revision: 2, spell_fragment: "typo".into(), ..snap(1, "I will recie") });
        assert_eq!(suggestion_for(&rx, 2).3.as_deref(), Some("typo"));
    }

    #[test]
    fn typo_gate_blocks_impossible_words_but_not_names() {
        let (c, rx) = core_with_events();
        let typo = |rev, text: &str| Snapshot { revision: rev, spell_fragment: "typo".into(), ..snap(1, text) };
        c.submit(typo(1, "I will recie"));
        assert_eq!(suggestion_for(&rx, 1).3.as_deref(), Some("typo"));
        c.submit(typo(2, "I met Priyan"));
        assert_eq!(suggestion_for(&rx, 2).1, "pending", "capitalized: maybe a name");
        c.submit(typo(3, "build v2b"));
        assert_eq!(suggestion_for(&rx, 3).1, "pending", "contains digits");
        c.submit(Snapshot { revision: 4, ..snap(1, "I will recie") });
        assert_eq!(suggestion_for(&rx, 4).1, "pending", "not checked: no gate");
    }

    #[test]
    fn hinglish_is_neither_gated_nor_corrected() {
        let (c, rx) = core_with_events();
        let fix = |rev, text: &str, word: &str, correction: &str| Snapshot {
            revision: rev,
            spell_word: word.into(),
            spell_correction: correction.into(),
            ..snap(1, text)
        };
        let typo = |rev, text: &str| Snapshot { revision: rev, spell_fragment: "typo".into(), ..snap(1, text) };
        // A listed word, even as the first word of the field.
        c.submit(fix(1, "hain ", "hain", "hair"));
        assert_ne!(suggestion_for(&rx, 1).1, "autocorrect", "a listed word");
        c.submit(typo(2, "ok jald"));
        assert_eq!(suggestion_for(&rx, 2).1, "pending", "the start of a listed word");
        // In Hinglish text, unlisted words are spared too.
        c.submit(fix(3, "Haan yaar, kal scene banate ", "banate", "banter"));
        assert_ne!(suggestion_for(&rx, 3).1, "autocorrect", "a word in Hinglish text");
        c.submit(typo(4, "Haan yaar, kal scene banat"));
        assert_eq!(suggestion_for(&rx, 4).1, "pending", "a fragment in Hinglish text");
        // English typos in English text are still fixed and gated.
        c.submit(fix(5, "Thanks for the notes, I will recieve ", "recieve", "receive"));
        assert_eq!(suggestion_for(&rx, 5).1, "autocorrect");
        c.submit(typo(6, "Thanks for the notes, I will recie"));
        assert_eq!(suggestion_for(&rx, 6).3.as_deref(), Some("typo"));
    }

    #[test]
    fn a_word_kept_earlier_in_the_field_is_known() {
        let (c, rx) = core_with_events();
        c.submit(Snapshot {
            revision: 1,
            spell_word: "dashbord".into(),
            spell_correction: "dashboard".into(),
            ..snap(1, "Ask Rohit about the dashbord. The dashbord ")
        });
        assert_ne!(suggestion_for(&rx, 1).1, "autocorrect", "kept the first time");
        c.submit(Snapshot { revision: 2, spell_fragment: "typo".into(), ..snap(1, "We use kubectx daily. Run kubec") });
        assert_eq!(suggestion_for(&rx, 2).1, "pending", "the start of a word already in the field");
    }

    fn my_details() -> UserDetails {
        UserDetails {
            name: "Priya Raman".into(),
            email: "priya.raman@example.com".into(),
            phone: "+91 98765 43210".into(),
            job_title: "Product Manager".into(),
            ..UserDetails::default()
        }
    }

    #[test]
    fn details_fill_the_exact_value() {
        let (c, rx) = core_with_events();
        c.set_details(my_details());
        c.submit(Snapshot { revision: 1, ..snap(1, "Thanks Sam. My email is ") });
        let (text, source, replace, _) = suggestion_for(&rx, 1);
        assert_eq!((text.as_str(), source, replace), ("priya.raman@example.com", "details", None));
        assert_eq!(c.accept(AcceptMode::NextWord).unwrap().insert, "priya.raman@example.com");
        // Typed through: still the exact rest, and the typo gate doesn't block it.
        c.submit(Snapshot { revision: 2, spell_fragment: "typo".into(), ..snap(1, "Thanks Sam. My email is priya.ra") });
        assert_eq!(suggestion_for(&rx, 2).0, "man@example.com");
        // A phone number is one unit too; a name goes word by word.
        c.submit(Snapshot { revision: 3, ..snap(1, "Call me on ") });
        assert_eq!(c.accept(AcceptMode::NextWord).unwrap().insert, "+91 98765 43210");
        c.submit(Snapshot { revision: 4, ..snap(1, "See you.\n\nBest regards,\n") });
        assert_eq!(suggestion_for(&rx, 4).0, "Priya Raman");
        assert_eq!(c.accept(AcceptMode::NextWord).unwrap().insert, "Priya");
    }

    #[test]
    fn details_fill_carries_its_label() {
        let (c, rx) = core_with_events();
        c.set_details(my_details());
        c.submit(Snapshot { revision: 1, ..snap(1, "my name is pri") });
        loop {
            if let Event::Suggestion { revision: 1, text, source, replace, label, .. } = rx.recv_timeout(Duration::from_secs(2)).unwrap() {
                assert_eq!((text.as_str(), source), ("Priya Raman", "details"));
                assert_eq!((replace.as_deref(), label.as_deref()), (Some("pri"), Some("name")));
                break;
            }
        }
    }

    #[test]
    fn details_never_fill_where_suggestions_are_off() {
        let (c, rx) = core_with_events();
        c.submit(Snapshot { revision: 1, ..snap(1, "My email is ") });
        assert_eq!(suggestion_for(&rx, 1).1, "pending", "no details set: the model as usual");
        c.set_details(my_details());
        c.submit(Snapshot { revision: 2, subrole: "AXSecureTextField".into(), ..snap(1, "My email is ") });
        assert_eq!(suggestion_for(&rx, 2).3.as_deref(), Some("secureField"));
        c.submit(Snapshot { revision: 3, secure_input: true, ..snap(1, "My email is ") });
        assert_eq!(suggestion_for(&rx, 3).1, "policy");
        c.configure(Settings { disabled_apps: vec!["com.apple.mail".into()], ..Settings::default() });
        c.submit(Snapshot { revision: 4, ..snap(1, "My email is ") });
        assert_eq!(suggestion_for(&rx, 4).3.as_deref(), Some("appDisabledByUser"));
        c.configure(Settings::default());
        c.submit(Snapshot { revision: 5, text_after: "and more text here".into(), ..snap(1, "My email is ") });
        assert_ne!(suggestion_for(&rx, 5).1, "details", "mid-line");
        c.submit(Snapshot { revision: 6, ..snap(1, "My email is x") });
        assert_eq!(suggestion_for(&rx, 6).1, "pending", "typed something else");
        c.set_details(UserDetails::default());
        c.submit(Snapshot { revision: 7, ..snap(1, "My email is ") });
        assert_eq!(suggestion_for(&rx, 7).1, "pending", "switched off");
    }

    #[test]
    fn writer_line_only_when_allowed_and_local() {
        let c = core();
        c.set_details(my_details());
        assert_eq!(*c.shared.writer.read().unwrap(), "", "off by default");
        c.set_details(UserDetails { in_prompt: true, ..my_details() });
        assert_eq!(*c.shared.writer.read().unwrap(), "Priya Raman (Product Manager)");
        let remote = Core::new(
            CoreConfig { backend: "openai".into(), backend_url: "http://127.0.0.1:9".into(), ..CoreConfig::default() },
            Box::new(|_| {}),
        );
        remote.set_details(UserDetails { in_prompt: true, ..my_details() });
        assert_eq!(*remote.shared.writer.read().unwrap(), "", "never sent to a server");
    }

    /// The next status event (skipping suggestions).
    fn status(rx: &std::sync::mpsc::Receiver<Event>) -> (&'static str, String) {
        loop {
            if let Event::Status { state, detail } = rx.recv_timeout(Duration::from_secs(2)).expect("status") {
                return (state, detail);
            }
        }
    }

    #[test]
    fn paused_core_loads_nothing_and_answers_paused() {
        let (tx, rx) = std::sync::mpsc::channel();
        let tx = Mutex::new(tx);
        let c = Core::new(
            CoreConfig {
                model_path: "/nonexistent.gguf".into(),
                settings: Settings { paused: true, ..Settings::default() },
                ..CoreConfig::default()
            },
            Box::new(move |e| {
                let _ = tx.lock().unwrap().send(e.clone());
            }),
        );
        // Started paused: no load attempt, just the pause.
        assert_eq!(status(&rx), ("paused", String::new()));
        c.submit(Snapshot { revision: 1, ..snap(1, "Thanks for the notes, I will") });
        assert_eq!(suggestion_for(&rx, 1).3.as_deref(), Some("paused"));
        assert!(c.shared.pending.lock().unwrap().is_none(), "nothing queued");
        c.warm(snap(1, "Thanks for the notes, I will"));
        assert!(c.shared.pending.lock().unwrap().is_none(), "no warm-up either");
        // Resumed: the model is not loaded yet; the next completion loads it (and fails here).
        c.configure(Settings::default());
        assert_eq!(status(&rx), ("idle", "model unloaded".into()));
        c.submit(Snapshot { revision: 2, ..snap(1, "Thanks for the notes, I will") });
        assert_eq!(suggestion_for(&rx, 2).1, "pending");
        assert_eq!(status(&rx).0, "loading");
    }

    fn sheet(visible: bool) -> Passage {
        Passage {
            app: "Numbers".into(),
            bundle_id: "com.apple.iWork.Numbers".into(),
            window_title: "Q3 budget".into(),
            text: "Contractors: $68,900 (budget $52,000)\nTravel: $11,200 (budget $14,000)".into(),
            captured_at: 0.0,
            visible,
            ..Passage::default()
        }
    }

    #[test]
    fn other_apps_text_heads_the_prompt_for_local_models_only() {
        let c = core();
        c.set_context(vec![sheet(true)]);
        let p = build_prompt(&c.shared, &snap(1, "Contractors came to sixty"), &c.settings(), &[], true);
        assert!(p.prefix.starts_with("[Also open: Numbers \u{2014} Q3 budget]\nContractors: $68,900"), "{}", p.prefix);
        assert_eq!(&p.prefix[p.others..], "Contractors came to");
        // The prefetch reuses the section; switching the feature off empties it.
        assert_eq!(build_prompt(&c.shared, &snap(1, "Contractors came to $68,900"), &c.settings(), &[], false).others, p.others);
        let off = Settings { other_apps_tokens: 0, ..c.settings() };
        assert_eq!(build_prompt(&c.shared, &snap(1, "Contractors came to $68"), &off, &[], true).others, 0);
        c.set_context(Vec::new());
        assert_eq!(build_prompt(&c.shared, &snap(1, "Contractors came to $68"), &c.settings(), &[], true).others, 0);
        // A server never sees it.
        let remote = Core::new(CoreConfig { backend: "openai".into(), backend_url: "http://127.0.0.1:9".into(), ..CoreConfig::default() }, Box::new(|_| {}));
        remote.set_context(vec![sheet(true)]);
        assert_eq!(build_prompt(&remote.shared, &snap(1, "Contractors came to $68"), &remote.settings(), &[], true).others, 0);
    }

    #[test]
    fn other_apps_section_leaves_room_for_the_rest_of_the_prompt() {
        let c = Core::new(CoreConfig { model_path: "/nonexistent.gguf".into(), n_ctx: 1600, ..CoreConfig::default() }, Box::new(|_| {}));
        c.set_context(vec![sheet(true)]);
        assert!(build_prompt(&c.shared, &snap(1, "Contractors came to $68"), &c.settings(), &[], true).others > 0);
        // Devanagari screen text costs about a token a character: no room is left.
        let hindi = "क्या आप कल की बैठक में आएँगे? ".repeat(50);
        let s = Snapshot { screen_context: hindi, ..snap(1, "Contractors came to $68") };
        assert_eq!(build_prompt(&c.shared, &s, &c.settings(), &[], true).others, 0);
        // A prompt that still overflows drops the section first.
        let p = build_prompt(&c.shared, &snap(1, "Contractors came to $68"), &c.settings(), &[], true);
        let q = without_others(&p).unwrap();
        assert_eq!(q.prefix, p.prefix[p.others..]);
        assert!(without_others(&q).is_none());
    }

    #[test]
    fn pausing_drops_queued_work_and_the_backend() {
        let (tx, rx) = std::sync::mpsc::channel();
        let tx = Mutex::new(tx);
        // A server backend loads without connecting, so the worker is up and idle.
        let c = Core::new(
            CoreConfig { backend: "openai".into(), backend_url: "http://127.0.0.1:9".into(), ..CoreConfig::default() },
            Box::new(move |e| {
                let _ = tx.lock().unwrap().send(e.clone());
            }),
        );
        assert_eq!(status(&rx).0, "ready");
        *c.shared.pending.lock().unwrap() = Some(Job {
            kind: JobKind::Warm,
            revision: 9,
            field_key: 1,
            text_before: String::new(),
            prompt: build_prompt(&c.shared, &snap(1, "x"), &Settings::default(), &[], true),
            queued: Instant::now(),
            snapshot: snap(1, "x"),
        });
        let before = c.shared.latest.load(Ordering::SeqCst);
        c.configure(Settings { paused: true, ..Settings::default() });
        assert!(c.shared.pending.lock().unwrap().is_none(), "queued job dropped");
        assert!(c.shared.latest.load(Ordering::SeqCst) > before, "a running job is cancelled");
        assert_eq!(status(&rx), ("paused", String::new()));
        // Same settings again: no second pause event, and the worker stays asleep.
        c.configure(Settings { paused: true, ..Settings::default() });
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());
        c.configure(Settings::default());
        assert_eq!(status(&rx).0, "ready", "a server client comes back at once");
    }

    #[test]
    fn personalization_off_records_nothing() {
        let c = core();
        c.configure(Settings { personalize: false, ..Settings::default() });
        c.submit(snap(1, "Hello"));
        assert!(c.shared.track.lock().unwrap().is_none());
    }
}
