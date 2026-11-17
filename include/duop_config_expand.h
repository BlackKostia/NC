/* include/duop_config_expand.h - shell command template expansion (src/core/config_expand.c). */
#pragma once
#include "duop_abi.h"

/* Values substituted into a template; every pointer may be NULL (expands to nothing). `selection` is a list of
 * NUL-separated names ended by an empty name. Layout matches the 40-byte asm context (5 pointers, 64-bit targets). */
typedef struct ConfigExpandCtx {
    const char *cur_name;       /* %f */
    const char *cur_path;       /* %p */
    const char *selection;      /* %F, %s */
    const char *active_dir;     /* %d */
    const char *inactive_dir;   /* %D */
} ConfigExpandCtx;

/* Expands %f %p %d %D %F %s %% in `tmpl` into the /bin/sh script `out` (cap bytes). Each value is escaped for the quoting
 * context at the placeholder. Returns 0, or -ENAMETOOLONG when it does not fit (out is then "": never run a cut-off script). */
intptr_t config_expand_cmd(const char *tmpl, char *out, size_t cap, const ConfigExpandCtx *ctx);
