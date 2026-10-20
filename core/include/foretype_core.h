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
void ft_engine_dismiss(FtEngine *engine, uint64_t field_key, const char *text_before);

bool ft_engine_configure(FtEngine *engine, const char *settings_json);

/// Installs the completer used when the config's backend is "shell".
void ft_engine_set_completer(FtEngine *engine, FtCompleteCallback callback, void *ctx);

/// Personalization: {"records": n, "words": n}; delete the history; import [{"app","text"}].
char *ft_engine_history_stats(FtEngine *engine);
bool ft_engine_clear_history(FtEngine *engine);
int64_t ft_engine_import_history(FtEngine *engine, const char *items_json);
bool ft_engine_open_history(FtEngine *engine, const char *path, const char *key_hex);
char *ft_engine_compat_rule(FtEngine *engine, const char *bundle_id);

/// Downloadable models for a machine with ram_gb of memory (JSON array, "recommended" set).
char *ft_model_catalog(uint32_t ram_gb);

void ft_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
