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

FtEngine *ft_engine_new(const char *config_json, FtEventCallback callback, void *ctx);
void ft_engine_free(FtEngine *engine);

void ft_engine_submit(FtEngine *engine, const char *snapshot_json);
void ft_engine_warm(FtEngine *engine, const char *snapshot_json);

/// mode 0 = next word, 1 = whole suggestion. Returns {"insert","remaining"} or NULL.
char *ft_engine_accept(FtEngine *engine, int32_t mode);
void ft_engine_dismiss(FtEngine *engine, uint64_t field_key, const char *text_before);

bool ft_engine_configure(FtEngine *engine, const char *settings_json);
char *ft_engine_compat_rule(FtEngine *engine, const char *bundle_id);

void ft_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
