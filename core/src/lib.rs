//! Foretype core: the platform-independent half of a system-wide inline autocomplete app.
//!
//! A native shell (Swift on macOS today) captures the focused text field, sends a
//! [`Snapshot`] per change, and renders whatever suggestion state comes back. This crate
//! owns everything in between: the policy gate, suggestion reuse (type-through, cache,
//! word-by-word accept), prompt building and llama.cpp inference on a dedicated thread.
//! It emits suggestion *state*, never pixels, so the same engine can sit behind an overlay
//! (macOS), a TSF text service (Windows) or an Fcitx5/IBus preedit (Linux).

pub mod context;
pub mod engine;
pub mod ffi;
pub mod policy;
pub mod session;
pub mod words;

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::context::{ContextInput, Prompt};
use crate::engine::{Engine, EngineConfig, GenError, GenOptions};
use crate::policy::CompatDb;
use crate::session::{AcceptMode, Session};

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
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            enabled: true,
            length_words: 4,
            stop_at_sentence_end: true,
            instructions: String::new(),
            disabled_apps: Vec::new(),
            enabled_apps: Vec::new(),
            only_apps: Vec::new(),
            deadline_ms: 300,
            max_body_chars: 1600,
            unload_after_s: 300,
            debounce_ms: 0,
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
        /// model | typeThrough | cache | pending | policy | dismissed | error
        source: &'static str,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ms: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        prefilled: Option<usize>,
        #[serde(skip_serializing_if = "Option::is_none")]
        stop: Option<&'static str>,
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
}

struct Shared {
    latest: AtomicU64,
    pending: Mutex<Option<Job>>,
    wake: Condvar,
    shutdown: AtomicBool,
    session: Mutex<Session>,
    settings: RwLock<Settings>,
    compat: CompatDb,
    sink: EventSink,
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
        let shared = Arc::new(Shared {
            latest: AtomicU64::new(0),
            pending: Mutex::new(None),
            wake: Condvar::new(),
            shutdown: AtomicBool::new(false),
            session: Mutex::new(Session::default()),
            settings: RwLock::new(config.settings.clone()),
            compat: CompatDb::bundled(),
            sink,
        });
        let engine_cfg = EngineConfig {
            model_path: config.model_path.clone(),
            n_ctx: config.n_ctx,
            n_gpu_layers: config.n_gpu_layers,
            n_threads: config.n_threads,
            ..EngineConfig::default()
        };
        let worker_shared = shared.clone();
        let worker = std::thread::Builder::new()
            .name("foretype.engine".into())
            .spawn(move || worker_loop(worker_shared, engine_cfg))
            .expect("spawn engine thread");
        Self { shared, worker: Some(worker) }
    }

    pub fn configure(&self, settings: Settings) {
        *self.shared.settings.write().unwrap() = settings;
        self.shared.session.lock().unwrap().clear();
    }

    pub fn settings(&self) -> Settings {
        self.shared.settings.read().unwrap().clone()
    }

    pub fn compat_rule(&self, bundle_id: &str) -> policy::AppRule {
        self.shared.compat.rule(bundle_id)
    }

    fn emit_suggestion(&self, revision: u64, text: String, source: &'static str, reason: Option<String>) {
        (self.shared.sink)(&Event::Suggestion { revision, text, source, reason, ms: None, prefilled: None, stop: None });
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
        if let Some(reason) = policy::evaluate(&snap, &self.shared.compat, &disabled, &enabled) {
            self.shared.session.lock().unwrap().clear();
            return self.emit_suggestion(rev, String::new(), "policy", Some(reason.into()));
        }
        // In a terminal only the agent prompt's own text is the document; the scrollback
        // above it reaches the model as screen context instead.
        if self.shared.compat.rule(&snap.bundle_id).agent_prompt_only && !enabled.contains(&snap.bundle_id) {
            if let Some(prompt) = self.shared.compat.agent_prompt_text(&snap.text_before) {
                snap.text_before = prompt.to_string();
            }
        }
        {
            let mut session = self.shared.session.lock().unwrap();
            if !snap.force && session.is_dismissed(snap.field_key, &snap.text_before) {
                return self.emit_suggestion(rev, String::new(), "dismissed", None);
            }
            if let Some(rest) = session.type_through(snap.field_key, &snap.text_before) {
                drop(session);
                return self.emit_suggestion(rev, rest, "typeThrough", None);
            }
            if let Some(hit) = session.cached(snap.field_key, &snap.text_before) {
                session.set(snap.field_key, &snap.text_before, &hit);
                drop(session);
                return self.emit_suggestion(rev, hit, "cache", None);
            }
            session.clear();
        }
        let prompt = build_prompt(&snap, &settings);
        self.enqueue(Job {
            kind: JobKind::Complete,
            revision: rev,
            field_key: snap.field_key,
            text_before: snap.text_before,
            prompt,
            queued: Instant::now(),
        });
        self.emit_suggestion(rev, String::new(), "pending", None);
    }

    /// Prefills the context for a newly focused field so the first suggestion is fast.
    /// Never displaces a queued completion.
    pub fn warm(&self, snap: Snapshot) {
        let settings = self.settings();
        let prompt = build_prompt(&snap, &settings);
        let mut pending = self.shared.pending.lock().unwrap();
        if pending.is_none() {
            *pending = Some(Job {
                kind: JobKind::Warm,
                revision: snap.revision,
                field_key: snap.field_key,
                text_before: snap.text_before,
                prompt,
                queued: Instant::now(),
            });
            self.shared.wake.notify_one();
        }
    }

    fn enqueue(&self, job: Job) {
        *self.shared.pending.lock().unwrap() = Some(job);
        self.shared.wake.notify_one();
    }

    /// Returns `(insert, remaining)` for Tab (next word) or accept-all.
    pub fn accept(&self, mode: AcceptMode) -> Option<(String, String)> {
        self.shared.session.lock().unwrap().accept(mode)
    }

    /// Hides the suggestion and suppresses new ones until the text changes.
    pub fn dismiss(&self, field_key: u64, text_before: &str) {
        self.shared.latest.fetch_add(1, Ordering::SeqCst);
        self.shared.session.lock().unwrap().dismiss(field_key, text_before);
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        self.shared.shutdown.store(true, Ordering::SeqCst);
        self.shared.latest.fetch_add(1, Ordering::SeqCst);
        self.shared.wake.notify_all();
        if let Some(w) = self.worker.take() {
            let _ = w.join();
        }
    }
}

fn build_prompt(snap: &Snapshot, settings: &Settings) -> Prompt {
    context::build(
        &ContextInput {
            app_name: &snap.app_name,
            window_title: &snap.window_title,
            url: &snap.url,
            instructions: &settings.instructions,
            screen_context: &snap.screen_context,
            text_before: &snap.text_before,
        },
        settings.max_body_chars,
    )
}

fn worker_loop(shared: Arc<Shared>, cfg: EngineConfig) {
    let load = |shared: &Shared| -> Option<Engine> {
        (shared.sink)(&Event::Status { state: "loading", detail: cfg.model_path.clone() });
        let t = Instant::now();
        match Engine::load(&cfg) {
            Ok(e) => {
                (shared.sink)(&Event::Status {
                    state: "ready",
                    detail: format!("loaded in {:.0} ms", t.elapsed().as_secs_f64() * 1000.0),
                });
                Some(e)
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
                if engine_slot.is_some() && unload_after > 0 && last_used.elapsed() >= Duration::from_secs(unload_after) {
                    drop(pending);
                    engine_slot = None;
                    (shared.sink)(&Event::Status { state: "idle", detail: "model unloaded".into() });
                    pending = shared.pending.lock().unwrap();
                    continue;
                }
                let timeout = if engine_slot.is_some() && unload_after > 0 {
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
                let opts = GenOptions {
                    max_words: settings.length_words.max(1),
                    deadline: Duration::from_millis(settings.deadline_ms),
                    stop_at_sentence_end: settings.stop_at_sentence_end,
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
                        shared.session.lock().unwrap().set(job.field_key, &job.text_before, &c.text);
                        (shared.sink)(&Event::Suggestion {
                            revision: rev,
                            text: c.text,
                            source: "model",
                            reason: None,
                            ms: Some(queue_ms),
                            prefilled: Some(c.prefilled_tokens),
                            stop: Some(c.stop),
                        });
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
                        });
                    }
                }
            }
        }
    }
}
