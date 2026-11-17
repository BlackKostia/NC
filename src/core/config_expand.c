/* src/core/config_expand.c - shell command template expansion for the User Menu and open rules
 * (freestanding C23; replaces config_expand.s).
 *
 *   %f current name   %p current full path   %d / %D active / opposite pane directory
 *   %F / %s  every marked name (or the current one): one shell word per name, space separated
 *   %%       a literal percent sign
 * Every value is escaped for the quoting context in force at the placeholder (none, '...' or "...") so no file
 * name can end its word; a backslash in the template protects the next byte. The expansion is all-or-nothing:
 * if it does not fit, the output is emptied and the command MUST NOT be run.
 */
#include "duop_config_expand.h"
#include "duop_pal.h"

enum { Q_NONE = 0, Q_SINGLE = 1, Q_DOUBLE = 2 };
#define OVERFLOW ((size_t)-1)

/* mode NONE: writes '<src>' with its own quotes; mode SINGLE: already inside '...' (no wrapper). ' becomes '\''.
 * Advances *src to its NUL; returns the new index or OVERFLOW. */
static size_t emit_sq(char *out, size_t i, size_t max, const char **src, int mode)
{
    const char *s = *src;
    if (mode == Q_NONE) {
        if (i >= max) return OVERFLOW;
        out[i++] = '\'';
    }
    for (; *s; s++) {
        if (*s == '\'') {
            if (i + 4 > max) return OVERFLOW;
            out[i++] = '\''; out[i++] = '\\'; out[i++] = '\''; out[i++] = '\'';
        } else {
            if (i >= max) return OVERFLOW;
            out[i++] = *s;
        }
    }
    if (mode == Q_NONE) {
        if (i >= max) return OVERFLOW;
        out[i++] = '\'';
    }
    *src = s;
    return i;
}

/* Inside "...": " \ $ ` get a backslash. */
static size_t emit_dq(char *out, size_t i, size_t max, const char **src)
{
    const char *s = *src;
    for (; *s; s++) {
        if (*s == '"' || *s == '\\' || *s == '$' || *s == '`') {
            if (i + 2 > max) return OVERFLOW;
            out[i++] = '\\';
        } else if (i >= max) {
            return OVERFLOW;
        }
        out[i++] = *s;
    }
    *src = s;
    return i;
}

/* One placeholder value escaped for `mode`; a list is emitted as space separated words. NULL emits nothing. */
static size_t emit_value(char *out, size_t i, size_t max, const char *val, int mode, bool is_list)
{
    if (!val) return i;
    for (;;) {
        i = mode == Q_DOUBLE ? emit_dq(out, i, max, &val) : emit_sq(out, i, max, &val, mode);
        if (i == OVERFLOW || !is_list || !val[1]) return i;
        val++;                                          /* step over the NUL to the next name */
        if (i >= max) return OVERFLOW;
        out[i++] = ' ';
    }
}

static int update_quote(int q, uint8_t ch)
{
    if (ch == '\'' && q != Q_DOUBLE) return q ^ Q_SINGLE;
    if (ch == '"' && q != Q_SINGLE) return q ^ Q_DOUBLE;
    return q;
}

/* Returns false when ch is not a placeholder letter. */
static bool lookup_var(uint8_t ch, const ConfigExpandCtx *c, const char **val, bool *is_list)
{
    *is_list = false;
    switch (ch) {
    case 'f': *val = c->cur_name; return true;
    case 'p': *val = c->cur_path; return true;
    case 'F': case 's': *val = c->selection; *is_list = true; return true;
    case 'd': *val = c->active_dir; return true;
    case 'D': *val = c->inactive_dir; return true;
    default: return false;
    }
}

static intptr_t too_long(char *out, size_t cap)
{
    if (cap) out[0] = 0;                                /* never leave a runnable half-command behind */
    return -ENAMETOOLONG;
}

intptr_t config_expand_cmd(const char *tmpl, char *out, size_t cap, const ConfigExpandCtx *ctx)
{
    if (!cap) return -ENAMETOOLONG;
    size_t max = cap - 1, i = 0;                        /* the last byte is reserved for the NUL */
    int q = Q_NONE;
    while (*tmpl) {
        if (tmpl[0] == '%' && tmpl[1] == '%') {
            if (i >= max) return too_long(out, cap);
            out[i++] = '%';
            tmpl += 2;
            continue;
        }
        const char *val;
        bool is_list;
        if (tmpl[0] == '%' && tmpl[1] && lookup_var((uint8_t)tmpl[1], ctx, &val, &is_list)) {
            tmpl += 2;
            i = emit_value(out, i, max, val, q, is_list);
            if (i == OVERFLOW) return too_long(out, cap);
            continue;
        }
        if (q != Q_SINGLE && tmpl[0] == '\\' && tmpl[1]) {   /* a backslash protects the next template byte */
            if (i + 2 > max) return too_long(out, cap);
            out[i++] = '\\';
            out[i++] = tmpl[1];
            tmpl += 2;
            continue;
        }
        q = update_quote(q, (uint8_t)tmpl[0]);
        if (i >= max) return too_long(out, cap);
        out[i++] = *tmpl++;
    }
    out[i] = 0;
    return 0;
}
