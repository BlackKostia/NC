/* tests/harness/script_cli.h - the common parts of the differential CLI harnesses (freestanding, header-only).
 *
 * A harness links ONE implementation per process (the frozen asm renamed ref_*, or the C module), reads a command script on stdin
 * (one command per line) and prints text the Python test diffs byte for byte against the other implementation's run:
 *     int duop_main(...) { char *script = sc_read_all(); for (char *line; (line = sc_next_line(&script));) { ... sc_hex(...) ... } sc_flush(); }
 * Output goes through sc_put / sc_num / sc_esc (non-ASCII and control bytes are \xNN escaped, so UTF-8 and NULs survive). */
#pragma once
#include "duop_string.h"
#include "duop_sys.h"

#define SC_UNUSED __attribute__((unused))

SC_UNUSED static char g_sc_script[16 << 20];
SC_UNUSED static char g_sc_out[1 << 16];
SC_UNUSED static size_t g_sc_out_n;

static inline void sc_flush(void)
{
    (void)os_write(1, g_sc_out, g_sc_out_n);
    g_sc_out_n = 0;
}
static inline void sc_put(const char *s)
{
    while (*s) {
        if (g_sc_out_n >= sizeof g_sc_out - 8) sc_flush();
        g_sc_out[g_sc_out_n++] = *s++;
    }
}
static inline void sc_num(int64_t v)
{
    char t[24];
    if (v < 0) { sc_put("-"); v = -v; }
    t[u64_to_dec((uint64_t)v, t)] = 0;
    sc_put(t);
}
static inline void sc_esc(const char *s)
{
    static const char hexd[] = "0123456789abcdef";
    for (; *s; s++) {
        uint8_t c = (uint8_t)*s;
        if (c >= 0x20 && c < 0x7F && c != '\\') { char t[2] = {(char)c, 0}; sc_put(t); }
        else { char t[5] = {'\\', 'x', hexd[c >> 4], hexd[c & 15], 0}; sc_put(t); }
    }
}

/* stdin -> NUL-terminated script (up to 16 MiB) */
static inline char *sc_read_all(void)
{
    size_t n = 0;
    for (;;) {
        intptr_t r = os_read(0, g_sc_script + n, sizeof g_sc_script - 1 - n);
        if (r <= 0) break;
        n += (size_t)r;
    }
    g_sc_script[n] = 0;
    return g_sc_script;
}

/* next line of the script (NUL-terminated in place, no '\n'), or nullptr at the end; *cursor advances */
static inline char *sc_next_line(char **cursor)
{
    char *line = *cursor;
    if (!*line) return nullptr;
    char *eol = line;
    while (*eol && *eol != '\n') eol++;
    *cursor = *eol ? eol + 1 : eol;
    *eol = 0;
    return line;
}

/* blank-separated numbers: sc_hex / sc_dec skip leading blanks, store the value and return the position after it */
static inline const char *sc_hex(const char *p, uint64_t *v)
{
    while (*p == ' ') p++;
    for (*v = 0;; p++) {
        int c = *p, d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
        if (d < 0) return p;
        *v = (*v << 4) | (uint64_t)d;
    }
}
static inline const char *sc_dec(const char *p, uint64_t *v)
{
    while (*p == ' ') p++;
    for (*v = 0; *p >= '0' && *p <= '9'; p++) *v = *v * 10 + (uint64_t)(*p - '0');
    return p;
}
