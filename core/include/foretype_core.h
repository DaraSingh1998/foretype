// Foretype core C ABI. All strings are UTF-8; JSON shapes are documented in core/src/lib.rs.
// Strings returned by the core must be released with ft_string_free.
#ifndef FORETYPE_CORE_H
#define FORETYPE_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FtEngine FtEngine;

/// Receives every event as JSON ({"type":"suggestion",...} or {"type":"status",...}).
/// Called on core threads, sometimes synchronously from ft_engine_submit.
typedef void (*FtEventCallback)(void *ctx, const char *event_json);

/// The "shell" backend's completer: {"prefix","max_words"} JSON in, the raw continuation out
/// as a malloc'd string (the core frees it) or NULL. Called on the engine thread; may block.
typedef char *(*FtCompleteCallback)(void *ctx, const char *request_json);

FtEngine *ft_engine_new(const char *config_json, FtEventCallback callback, void *ctx);
void ft_engine_free(FtEngine *engine);

void ft_engine_submit(FtEngine *engine, const char *snapshot_json);
void ft_engine_warm(FtEngine *engine, const char *snapshot_json);

/// mode 0 = next word, 1 = whole suggestion. Returns {"insert","remaining","replace"} or NULL;
/// a non-empty "replace" is the text just before the caret to delete before inserting.
char *ft_engine_accept(FtEngine *engine, int32_t mode);
/// Word alternatives (settings "alternatives"): takes the next word of alternative `index`
/// (0-based, as the last suggestion event's "alternatives" listed them), which becomes the
/// suggestion. Returns {"insert","remaining","replace":""} or NULL when there is none.
char *ft_engine_accept_alternative(FtEngine *engine, int32_t index);
/// Asks for alternatives on demand to the suggestion showing for this (latest) snapshot. The
/// answer is a suggestion event with the same revision and text, "source": "alternatives" and
/// "alternatives" (possibly empty), at once or after a wider beam search; none when
/// alternatives are off, the snapshot isn't the latest or no continuation shows for its text.
void ft_engine_alternatives(FtEngine *engine, const char *snapshot_json);
void ft_engine_dismiss(FtEngine *engine, uint64_t field_key, const char *text_before);

/// Replaces the settings (JSON). "paused": true drops queued work, frees the model and sends
/// {"type":"status","state":"paused"}; submit then answers with a "paused" hide and warm does
/// nothing. "paused": false resumes (status "idle"; the model loads on the next suggestion).
bool ft_engine_configure(FtEngine *engine, const char *settings_json);

/// The user's own details: {"name","email","phone","company","job_title","address","website",
/// "in_prompt"}. Fields the user switched off are empty; all empty turns fills off. Filled in
/// as "details" suggestions when the text asks for one; never logged.
bool ft_engine_set_details(FtEngine *engine, const char *details_json);

/// Text from other apps' windows, sent only when it changes: {"passages": [{"app","bundle_id",
/// "window_title","url_host","text","captured_at" (seconds since 1970),"visible","display"}]}.
/// The core picks the passages relevant to each prompt within the settings' other_apps_tokens.
/// {"passages": []} clears it; ignored with a server backend. False if the JSON doesn't parse.
bool ft_engine_set_context(FtEngine *engine, const char *context_json);

/// What the core holds of other apps' text and what the last prompt took from it (read only,
/// for the shell's "What Foretype sees" view): {"server","windows","passages","budget",
/// "changes","last": null | {"at","tokens","left_out","gone","passages": [{"label","app",
/// "bundle_id","ordinal","tokens","text"}]}}. Tokens are estimates; passages whose window left
/// the pool are only counted ("gone"). Free with ft_string_free.
char *ft_engine_context_report(FtEngine *engine);

/// Installs the completer used when the config's backend is "shell".
void ft_engine_set_completer(FtEngine *engine, FtCompleteCallback callback, void *ctx);

/// Personalization: {"records": n, "words": n, "locked": bool} (locked: the file's key opens
/// none of it, so it is kept read-only until deleted); delete the history; import [{"app","text"}].
char *ft_engine_history_stats(FtEngine *engine);
bool ft_engine_clear_history(FtEngine *engine);
int64_t ft_engine_import_history(FtEngine *engine, const char *items_json);
bool ft_engine_open_history(FtEngine *engine, const char *path, const char *key_hex);
char *ft_engine_compat_rule(FtEngine *engine, const char *bundle_id);

/// Downloadable models for a machine with ram_gb of memory (JSON array, "recommended" set).
char *ft_model_catalog(uint32_t ram_gb);

/// The custom instructions a fresh install starts with: {"global", "apps": {bundle id: note}}.
char *ft_default_instructions(void);

/// The website of a page URL, for keying its instructions ("site_instructions" in the
/// settings): {"host": "mail.google.com", "domain": "google.com"}, or null for a page that
/// isn't http(s). Free with ft_string_free.
char *ft_site_of(const char *url);

void ft_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
