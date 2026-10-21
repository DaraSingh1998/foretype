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
pub mod emoji;
pub mod engine;
pub mod ffi;
pub mod history;
pub mod models;
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
use crate::engine::{Engine, EngineConfig, GenError, GenOptions};
use crate::history::{History, Record};
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
        /// model | typeThrough | cache | pending | policy | dismissed | error | emoji | autocorrect
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
        /// What a replacement stands for, for display (`:tada:`, the misspelled word).
        #[serde(skip_serializing_if = "Option::is_none")]
        label: Option<String>,
    },
    /// Engine lifecycle: loading | ready | error.
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
        });
        let engine_cfg = EngineConfig {
            model_path: config.model_path.clone(),
            n_ctx: config.n_ctx,
            n_gpu_layers: config.n_gpu_layers,
            n_threads: config.n_threads,
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
        *self.shared.settings.write().unwrap() = settings;
        self.shared.session.lock().unwrap().clear();
        self.shared.examples.lock().unwrap().clear();
    }

    /// (records, distinct words) in the personalization history.
    pub fn history_stats(&self) -> (usize, usize) {
        (self.shared.history.lock().unwrap().records().len(), self.shared.profile.lock().unwrap().word_count())
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
                p.add_text(&text);
                h.append(Record::now(&app, text.trim()))?;
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

    /// Handles a field change. Returns synchronously for policy decisions and reused
    /// suggestions; otherwise queues inference (latest wins) and emits a `pending` hide.
    pub fn submit(&self, mut snap: Snapshot) {
        let rev = snap.revision;
        self.shared.latest.store(rev, Ordering::SeqCst);
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
        let prompt = build_prompt(&snap, &settings, &examples);
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

    /// Emoji shortcodes, autocorrect and the typo gate, which answer without the model.
    /// `Some(())` means an event was emitted.
    fn typing_aids(&self, snap: &Snapshot, settings: &Settings) -> Option<()> {
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
            let (_, fragment) = words::split_fragment(&snap.text_before);
            if !self.plausible_word(words::fragment_word(fragment)) {
                self.emit_suggestion(snap.revision, String::new(), "policy", Some("typo".into()));
                return Some(());
            }
        }
        None
    }

    /// A fragment the spell checker doesn't know may still be a real word: names and
    /// brands (capitalized), acronyms and codes (digits, all caps), very short fragments,
    /// and the user's own vocabulary.
    fn plausible_word(&self, w: &str) -> bool {
        let mut chars = w.chars();
        let Some(first) = chars.next() else { return true };
        if w.chars().count() < 3 || first.is_uppercase() || w.chars().any(|c| c.is_ascii_digit()) {
            return true;
        }
        self.shared.profile.lock().unwrap().has_prefix(&w.to_lowercase())
    }

    /// `(replace, insert)` for the misspelled word just finished, when it should be fixed:
    /// not a name in mid-sentence, not an acronym or code, not one of the user's own words.
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
        if (capitalized && !sentence_start)
            || word.chars().any(|c| c.is_ascii_digit())
            || word.chars().filter(|c| c.is_alphabetic()).all(char::is_uppercase)
            || self.shared.profile.lock().unwrap().knows(&word.to_lowercase())
        {
            return None;
        }
        Some((format!("{word}{spaces}"), format!("{fix}{spaces}")))
    }

    /// Prefills the context for a newly focused field so the first suggestion is fast.
    /// Never displaces a queued completion.
    pub fn warm(&self, snap: Snapshot) {
        let settings = self.settings();
        let examples = self.examples_for(&snap, &settings);
        let prompt = build_prompt(&snap, &settings, &examples);
        let mut pending = self.shared.pending.lock().unwrap();
        if pending.is_none() {
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
        *self.shared.pending.lock().unwrap() = Some(job);
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

fn build_prompt(snap: &Snapshot, settings: &Settings, examples: &[String]) -> Prompt {
    let instructions = settings.instructions_for(&snap.bundle_id);
    let mut prompt = context::build(
        &ContextInput {
            app_name: &snap.app_name,
            window_title: &snap.window_title,
            url: &snap.url,
            instructions: &instructions,
            screen_context: &snap.screen_context,
            examples,
            text_before: &snap.text_before,
        },
        settings.max_body_chars,
    );
    if settings.mid_line {
        prompt.suffix = line_suffix(snap).chars().take(MAX_SUFFIX_CHARS).collect();
    }
    prompt
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
    fn warm(&mut self, prefix: &str, cancel: &dyn Fn() -> bool) -> Result<usize, GenError> {
        match self {
            Runner::Local(e) => e.warm(prefix, cancel),
            Runner::Remote(b) => b.warm(prefix),
        }
    }

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
    let Some(first) = load(&shared) else { return };
    let mut engine_slot = Some(first);
    let mut last_used = Instant::now();
    let mut applied_gen = 0u64;

    loop {
        let job = {
            let mut pending = shared.pending.lock().unwrap();
            loop {
                if shared.shutdown.load(Ordering::SeqCst) {
                    return;
                }
                if let Some(job) = pending.take() {
                    break job;
                }
                // Idle: free the model's memory (Cotypist does the same) until needed again.
                let unload_after = shared.settings.read().unwrap().unload_after_s;
                let local = engine_slot.as_ref().is_some_and(Runner::is_local);
                if local && unload_after > 0 && last_used.elapsed() >= Duration::from_secs(unload_after) {
                    drop(pending);
                    engine_slot = None;
                    applied_gen = 0;
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
            JobKind::Warm => {
                let r = engine.warm(&job.prompt.prefix, &|| shared.pending.lock().map(|p| p.is_some()).unwrap_or(false));
                if debug() {
                    eprintln!("[foretype] warm rev={rev} -> {r:?}");
                }
            }
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
                match engine.complete(&job.prompt, &opts, &cancel) {
                    Ok(c) => {
                        let queue_ms = job.queued.elapsed().as_secs_f64() * 1000.0;
                        if debug() {
                            eprintln!(
                                "[foretype] rev={rev} prefill={} tok/{:.1}ms gen={} total={:.1}ms queue+total={queue_ms:.1}ms stop={} {:?}",
                                c.prefilled_tokens, c.prefill_ms, c.generated_tokens, c.total_ms, c.stop, c.text
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
                        // request cancels this between decode steps.
                        if settings.prefetch && !mid_line && !shown.trim().is_empty() {
                            let mut next = job.snapshot.clone();
                            next.text_before = format!("{}{}", job.text_before, shown);
                            let examples = shared.examples.lock().unwrap().get(&job.field_key).cloned().unwrap_or_default();
                            let prompt = build_prompt(&next, &settings, &examples);
                            let busy = || {
                                shared.shutdown.load(Ordering::SeqCst)
                                    || shared.pending.lock().map(|p| p.is_some()).unwrap_or(true)
                            };
                            if !busy() {
                                if let Ok(p) = engine.complete(&prompt, &opts, &busy) {
                                    if !p.text.trim().is_empty() {
                                        shared.session.lock().unwrap().remember(job.field_key, &next.text_before, &p.text);
                                        if debug() {
                                            eprintln!("[foretype] prefetched {:?} after {:?}", p.text, shown);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Err(GenError::Cancelled) => {}
                    Err(GenError::Failed(e)) => {
                        (shared.sink)(&Event::Suggestion {
                            revision: rev,
                            text: String::new(),
                            source: "error",
                            reason: Some(e),
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
        c.configure(Settings { autocorrect: false, ..Settings::default() });
        c.submit(fix(7, "I will recieve ", "recieve", "receive"));
        assert_ne!(suggestion_for(&rx, 7).1, "autocorrect", "turned off");
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
    fn personalization_off_records_nothing() {
        let c = core();
        c.configure(Settings { personalize: false, ..Settings::default() });
        c.submit(snap(1, "Hello"));
        assert!(c.shared.track.lock().unwrap().is_none());
    }
}
