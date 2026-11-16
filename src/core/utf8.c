/* src/core/utf8.c - UTF-8 codec and terminal display width (freestanding C23; replaces utf8.s).
 *
 * Contracts kept bit-for-bit from the assembly version (differentially tested, see tests/test_c_utf8.py):
 *   utf8_decode      -> {codepoint, bytes consumed}; {0,0} only on NUL, {U+FFFD,1} on any malformed byte.
 *                       The pair is returned in rax:rdx (x0:x1 on AArch64), which the asm callers rely on.
 *   utf8_encode      -> byte count 1..4 (>U+10FFFF becomes U+FFFD); buf needs 4 bytes.
 *   utf8_char_width  -> 0 (control/combining), 1, or 2 (wide CJK/Emoji).
 */
#include "duop_abi.h"

typedef struct { uint64_t cp, len; } Utf8Dec;

#define IS_CONT(b)  (((b) & 0xC0u) == 0x80u)
#define BAD         ((Utf8Dec){0xFFFD, 1})

Utf8Dec utf8_decode(const char *s)
{
    const uint8_t *p = (const uint8_t *)s;
    uint32_t c = p[0];
    if (c == 0) return (Utf8Dec){0, 0};
    if (c < 0x80) return (Utf8Dec){c, 1};
    if ((c & 0xE0u) == 0xC0u) {
        if (!IS_CONT(p[1])) return BAD;
        uint32_t cp = ((c & 0x1Fu) << 6) | (p[1] & 0x3Fu);
        return cp < 0x80 ? BAD : (Utf8Dec){cp, 2};
    }
    if ((c & 0xF0u) == 0xE0u) {
        if (!IS_CONT(p[1]) || !IS_CONT(p[2])) return BAD;
        uint32_t cp = ((c & 0x0Fu) << 12) | ((p[1] & 0x3Fu) << 6) | (p[2] & 0x3Fu);
        return cp < 0x800 ? BAD : (Utf8Dec){cp, 3};
    }
    if ((c & 0xF8u) == 0xF0u) {
        if (!IS_CONT(p[1]) || !IS_CONT(p[2]) || !IS_CONT(p[3])) return BAD;
        uint32_t cp = ((c & 0x07u) << 18) | ((p[1] & 0x3Fu) << 12) | ((p[2] & 0x3Fu) << 6) | (p[3] & 0x3Fu);
        return (cp < 0x10000 || cp > 0x10FFFF) ? BAD : (Utf8Dec){cp, 4};
    }
    return BAD;
}

int utf8_encode(uint32_t cp, char *out)
{
    uint8_t *b = (uint8_t *)out;
    if (cp < 0x80) { b[0] = (uint8_t)cp; return 1; }
    if (cp < 0x800) {
        b[0] = (uint8_t)(0xC0 | (cp >> 6));
        b[1] = (uint8_t)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp > 0x10FFFF) cp = 0xFFFD;
    if (cp < 0x10000) {
        b[0] = (uint8_t)(0xE0 | (cp >> 12));
        b[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (uint8_t)(0x80 | (cp & 0x3F));
        return 3;
    }
    b[0] = (uint8_t)(0xF0 | (cp >> 18));
    b[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
    b[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
    b[3] = (uint8_t)(0x80 | (cp & 0x3F));
    return 4;
}

static inline bool in_range(uint32_t v, uint32_t lo, uint32_t hi) { return v >= lo && v <= hi; }

int utf8_char_width(uint32_t cp)
{
    if (cp < 0x20) return 0;
    if (cp < 0x7F) return 1;
    if (cp < 0xA0) return 0;
    if (in_range(cp, 0x0300, 0x036F) || in_range(cp, 0xFE00, 0xFE0F)) return 0;   /* combining, variation selectors */
    if (in_range(cp, 0x1100, 0x115F) || in_range(cp, 0x2E80, 0xA4CF) || in_range(cp, 0xAC00, 0xD7A3) ||
        in_range(cp, 0xF900, 0xFAFF) || in_range(cp, 0xFF00, 0xFF60) || in_range(cp, 0x1F300, 0x1FAFF) ||
        in_range(cp, 0x20000, 0x2FFFD))
        return 2;
    return 1;
}

int utf8_display_width(const char *s)
{
    int w = 0;
    if (!s) return 0;
    for (;;) {
        Utf8Dec d = utf8_decode(s);
        if (d.len == 0) return w;
        s += d.len;
        w += utf8_char_width((uint32_t)d.cp);
    }
}
