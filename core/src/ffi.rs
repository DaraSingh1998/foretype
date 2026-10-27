//! C ABI for native shells. All strings are UTF-8 JSON; strings returned by the core must
//! be released with `ft_string_free`. Events are delivered on the core's own threads.

use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;

use crate::session::AcceptMode;
use crate::{Core, CoreConfig, Event, Settings, Snapshot};

pub type FtEventCallback = extern "C" fn(ctx: *mut c_void, event_json: *const c_char);

/// The shell's completer for the "shell" backend: request JSON in, continuation out as a
/// malloc'd string (the core frees it) or null.
pub type FtCompleteCallback = extern "C" fn(ctx: *mut c_void, request_json: *const c_char) -> *mut c_char;

extern "C" {
    fn free(p: *mut c_void);
}

pub struct FtEngine {
    core: Core,
}

struct CallbackCtx(*mut c_void);
// SAFETY: the shell promises its context pointer may be used from any thread.
unsafe impl Send for CallbackCtx {}
unsafe impl Sync for CallbackCtx {}

unsafe fn read_str<'a>(s: *const c_char) -> Option<&'a str> {
    if s.is_null() {
        return None;
    }
    CStr::from_ptr(s).to_str().ok()
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s).map_or(ptr::null_mut(), CString::into_raw)
}

/// Creates the engine and starts loading the model in the background. Progress arrives
/// as `status` events. Returns null if `config_json` does not parse.
///
/// # Safety
/// `config_json` must be a valid C string. `callback` must stay callable, and `ctx` valid,
/// until `ft_engine_free` returns.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_new(
    config_json: *const c_char,
    callback: FtEventCallback,
    ctx: *mut c_void,
) -> *mut FtEngine {
    let Some(cfg) = read_str(config_json).and_then(|s| serde_json::from_str::<CoreConfig>(s).ok()) else {
        return ptr::null_mut();
    };
    let cctx = CallbackCtx(ctx);
    let sink = Box::new(move |ev: &Event| {
        let cctx = &cctx;
        if let Ok(json) = serde_json::to_string(ev) {
            if let Ok(c) = CString::new(json) {
                callback(cctx.0, c.as_ptr());
            }
        }
    });
    Box::into_raw(Box::new(FtEngine { core: Core::new(cfg, sink) }))
}

/// # Safety
/// `engine` must come from `ft_engine_new` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_free(engine: *mut FtEngine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

/// # Safety
/// `engine` must be live; `snapshot_json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_submit(engine: *mut FtEngine, snapshot_json: *const c_char) {
    let (Some(e), Some(s)) = (engine.as_ref(), read_str(snapshot_json)) else { return };
    match serde_json::from_str::<Snapshot>(s) {
        Ok(snap) => e.core.submit(snap),
        Err(err) => eprintln!("[foretype] bad snapshot json: {err}"),
    }
}

/// # Safety
/// `engine` must be live; `snapshot_json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_warm(engine: *mut FtEngine, snapshot_json: *const c_char) {
    let (Some(e), Some(s)) = (engine.as_ref(), read_str(snapshot_json)) else { return };
    if let Ok(snap) = serde_json::from_str::<Snapshot>(s) {
        e.core.warm(snap);
    }
}

/// New screen text for the latest snapshot while the user pauses: the model runs again for it
/// (past the cache, with no `pending` hide first), or the prompt is only prefilled where no
/// model suggestion would show.
///
/// # Safety
/// `engine` must be live; `snapshot_json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_refresh(engine: *mut FtEngine, snapshot_json: *const c_char) {
    let (Some(e), Some(s)) = (engine.as_ref(), read_str(snapshot_json)) else { return };
    if let Ok(snap) = serde_json::from_str::<Snapshot>(s) {
        e.core.refresh(snap);
    }
}

/// Accepts the next word (`mode` 0) or the whole suggestion (`mode` 1). Returns
/// `{"insert": "...", "remaining": "...", "replace": "..."}` (delete `replace` before the
/// caret first; empty for a continuation), or null when nothing is showing.
///
/// # Safety
/// `engine` must be live.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_accept(engine: *mut FtEngine, mode: i32) -> *mut c_char {
    let Some(e) = engine.as_ref() else { return ptr::null_mut() };
    let mode = if mode == 1 { AcceptMode::All } else { AcceptMode::NextWord };
    match e.core.accept(mode) {
        Some(a) => to_c(serde_json::json!({ "insert": a.insert, "remaining": a.remaining, "replace": a.replace }).to_string()),
        None => ptr::null_mut(),
    }
}

/// Takes the next word of alternative `index` (0-based, in the order the last `suggestion`
/// event listed them), which becomes the suggestion: returns `{"insert", "remaining",
/// "replace": ""}` as `ft_engine_accept` does, or null when there is no such alternative.
///
/// # Safety
/// `engine` must be live.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_accept_alternative(engine: *mut FtEngine, index: i32) -> *mut c_char {
    let Some(e) = engine.as_ref() else { return ptr::null_mut() };
    let Ok(index) = usize::try_from(index) else { return ptr::null_mut() };
    match e.core.accept_alternative(index) {
        Some(a) => to_c(serde_json::json!({ "insert": a.insert, "remaining": a.remaining, "replace": a.replace }).to_string()),
        None => ptr::null_mut(),
    }
}

/// Asks for word alternatives on demand (D50) to the suggestion showing for `snapshot_json`,
/// the latest snapshot submitted. The answer is a `suggestion` event for its revision with
/// the same `text`, `source` `alternatives` and `alternatives` (possibly none): at once when
/// they are known, else after a wider beam search that typing cancels. Nothing comes when
/// alternatives are off, the snapshot isn't the latest or no continuation shows for its text.
///
/// # Safety
/// `engine` must be live; `snapshot_json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_alternatives(engine: *mut FtEngine, snapshot_json: *const c_char) {
    let (Some(e), Some(s)) = (engine.as_ref(), read_str(snapshot_json)) else { return };
    if let Ok(snap) = serde_json::from_str::<Snapshot>(s) {
        e.core.request_alternatives(snap);
    }
}

/// # Safety
/// `engine` must be live; `text_before` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_dismiss(engine: *mut FtEngine, field_key: u64, text_before: *const c_char) {
    let Some(e) = engine.as_ref() else { return };
    e.core.dismiss(field_key, read_str(text_before).unwrap_or(""));
}

/// Replaces the settings. Returns false if the JSON does not parse. `"paused": true` stops
/// everything: queued work is dropped, the model is freed and a `paused` status is sent;
/// `submit` then answers with a `paused` hide and `warm` does nothing until `"paused": false`.
///
/// # Safety
/// `engine` must be live; `settings_json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_configure(engine: *mut FtEngine, settings_json: *const c_char) -> bool {
    let (Some(e), Some(s)) = (engine.as_ref(), read_str(settings_json)) else { return false };
    match serde_json::from_str::<Settings>(s) {
        Ok(settings) => {
            e.core.configure(settings);
            true
        }
        Err(_) => false,
    }
}

/// Sets the user's own details: `{"name","email","phone","company","job_title","address",
/// "website","in_prompt"}` (all optional; empty strings for fields the user switched off, all
/// empty to turn the feature off). Returns false if the JSON does not parse.
///
/// # Safety
/// `engine` must be live; `details_json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_set_details(engine: *mut FtEngine, details_json: *const c_char) -> bool {
    let (Some(e), Some(s)) = (engine.as_ref(), read_str(details_json)) else { return false };
    match serde_json::from_str::<crate::details::UserDetails>(s) {
        Ok(d) => {
            e.core.set_details(d);
            true
        }
        Err(_) => false,
    }
}

/// Replaces the pool of other apps' text (D42), sent when the pool changes, not with each
/// snapshot: `{"passages": [{"app", "bundle_id", "window_title", "url_host", "text",
/// "captured_at" (seconds since 1970), "visible", "display"}]}`. `{"passages": []}` clears it.
/// Ignored with a server backend. Returns false if the JSON does not parse.
///
/// # Safety
/// `engine` must be live; `context_json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_set_context(engine: *mut FtEngine, context_json: *const c_char) -> bool {
    let (Some(e), Some(s)) = (engine.as_ref(), read_str(context_json)) else { return false };
    match serde_json::from_str::<crate::others::ContextUpdate>(s) {
        Ok(u) => {
            e.core.set_context(u.passages);
            true
        }
        Err(_) => false,
    }
}

/// What the core holds of other apps' text and what the last prompt took from it, for the
/// shell's "What Foretype sees" view: `{"server": bool, "windows": n, "passages": n, "budget":
/// n, "changes": n, "last": null | {"at" (seconds since 1970), "tokens", "left_out", "gone",
/// "passages": [{"label", "app", "bundle_id", "ordinal", "tokens", "text"}]}}`. Tokens are the
/// core's estimate, the budget's unit. Only text already in memory: passages whose window has
/// left the pool since are counted in `gone`, not shown. Read only; free with `ft_string_free`.
///
/// # Safety
/// `engine` must be live.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_context_report(engine: *mut FtEngine) -> *mut c_char {
    let Some(e) = engine.as_ref() else { return ptr::null_mut() };
    to_c(serde_json::to_string(&e.core.context_report()).unwrap_or_else(|_| "{}".into()))
}

/// Compatibility rule for a bundle ID as JSON (`disabled`, `insertion`, `prime`, `note`).
///
/// # Safety
/// `engine` must be live; `bundle_id` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_compat_rule(engine: *mut FtEngine, bundle_id: *const c_char) -> *mut c_char {
    let (Some(e), Some(b)) = (engine.as_ref(), read_str(bundle_id)) else { return ptr::null_mut() };
    to_c(serde_json::to_string(&e.core.compat_rule(b)).unwrap_or_else(|_| "{}".into()))
}

/// Installs the completer the "shell" backend asks for continuations (on macOS, Apple's
/// on-device model). Called on the core's engine thread; it may block.
///
/// # Safety
/// `engine` must be live; `callback` must stay callable, and `ctx` valid, until
/// `ft_engine_free` returns.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_set_completer(engine: *mut FtEngine, callback: FtCompleteCallback, ctx: *mut c_void) {
    let Some(e) = engine.as_ref() else { return };
    let cctx = CallbackCtx(ctx);
    e.core.set_completer(Box::new(move |req: &str| {
        let cctx = &cctx;
        let req = CString::new(req).ok()?;
        let out = callback(cctx.0, req.as_ptr());
        if out.is_null() {
            return None;
        }
        // SAFETY: the shell returns a malloc'd, NUL-terminated string.
        let s = CStr::from_ptr(out).to_string_lossy().into_owned();
        free(out.cast());
        Some(s)
    }));
}

/// # Safety
/// `s` must come from this library (or be null).
#[no_mangle]
pub unsafe extern "C" fn ft_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Personalization history size as `{"records": n, "words": n, "locked": bool}`. `locked`:
/// the file is there but its key opens none of it (or it can't be read); it is kept as it
/// is, nothing is recorded or imported, and only clearing it unlocks it.
///
/// # Safety
/// `engine` must be live.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_history_stats(engine: *mut FtEngine) -> *mut c_char {
    let Some(e) = engine.as_ref() else { return ptr::null_mut() };
    let (records, words) = e.core.history_stats();
    to_c(serde_json::json!({ "records": records, "words": words, "locked": e.core.history_locked() }).to_string())
}

/// Deletes the personalization history (file included). Returns false on failure.
///
/// # Safety
/// `engine` must be live.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_clear_history(engine: *mut FtEngine) -> bool {
    engine.as_ref().is_some_and(|e| e.core.clear_history().is_ok())
}

/// Imports earlier writing: a JSON array of `{"app": "...", "text": "..."}`. Returns the
/// number of records added, or -1 on error.
///
/// # Safety
/// `engine` must be live; `items_json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_import_history(engine: *mut FtEngine, items_json: *const c_char) -> i64 {
    #[derive(serde::Deserialize)]
    struct Item {
        #[serde(default)]
        app: String,
        text: String,
    }
    let (Some(e), Some(s)) = (engine.as_ref(), read_str(items_json)) else { return -1 };
    let Ok(items) = serde_json::from_str::<Vec<Item>>(s) else { return -1 };
    match e.core.import_history(items.into_iter().map(|i| (i.app, i.text)).collect()) {
        Ok(n) => n as i64,
        Err(_) => -1,
    }
}

/// Opens the encrypted history at `path` with a 64-hex-character key.
///
/// # Safety
/// `engine` must be live; `path` and `key_hex` valid C strings.
#[no_mangle]
pub unsafe extern "C" fn ft_engine_open_history(engine: *mut FtEngine, path: *const c_char, key_hex: *const c_char) -> bool {
    let (Some(e), Some(p), Some(k)) = (engine.as_ref(), read_str(path), read_str(key_hex)) else { return false };
    e.core.open_history(p, k)
}

/// The downloadable model catalog for a machine with `ram_gb` of memory, as a JSON array
/// (`id`, `name`, `tier`, `file`, `url`, `sha256`, `bytes`, `min_ram_gb`, `license`,
/// `recommended`). Needs no engine.
#[no_mangle]
pub extern "C" fn ft_model_catalog(ram_gb: u32) -> *mut c_char {
    to_c(serde_json::to_string(&crate::models::catalog(ram_gb)).unwrap_or_else(|_| "[]".into()))
}

/// The custom instructions a fresh install starts with: `{"global": "...", "apps": {"<bundle
/// id>": "..."}}`. Needs no engine.
#[no_mangle]
pub extern "C" fn ft_default_instructions() -> *mut c_char {
    to_c(serde_json::to_string(&crate::instructions::defaults()).unwrap_or_else(|_| "{}".into()))
}

/// The website a page URL belongs to, for keying a website's instructions: `{"host":
/// "mail.google.com", "domain": "google.com"}` (lowercase, no port or leading "www."; the
/// domain is the host itself when it has no shorter one), or `null` for a page that isn't
/// http(s) or a null `url`. Needs no engine.
///
/// # Safety
/// `url` must be null or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ft_site_of(url: *const c_char) -> *mut c_char {
    let site = read_str(url).and_then(crate::instructions::site_of);
    to_c(serde_json::to_string(&site).unwrap_or_else(|_| "null".into()))
}
