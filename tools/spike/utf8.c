/* Spike (Етап 0.0): src/core/utf8.s у freestanding C23. Контракт: SysV, повернення пари rax:rdx. */
#include <stdint.h>

typedef struct { uint64_t cp; uint64_t len; } Utf8Dec;

#define CONT(b) (((b) & 0xC0u) == 0x80u)

Utf8Dec utf8_decode(const uint8_t *p)
{
    uint32_t c = p[0];
    if (c == 0) return (Utf8Dec){0, 0};
    if (c < 0x80) return (Utf8Dec){c, 1};
    if ((c & 0xE0u) == 0xC0u) {
        uint32_t b1 = p[1];
        if (!CONT(b1)) goto bad;
        uint32_t cp = ((c & 0x1Fu) << 6) | (b1 & 0x3Fu);
        if (cp < 0x80) goto bad;
        return (Utf8Dec){cp, 2};
    }
    if ((c & 0xF0u) == 0xE0u) {
        uint32_t b1 = p[1];
        if (!CONT(b1)) goto bad;
        uint32_t b2 = p[2];
        if (!CONT(b2)) goto bad;
        uint32_t cp = ((c & 0x0Fu) << 12) | ((b1 & 0x3Fu) << 6) | (b2 & 0x3Fu);
        if (cp < 0x800) goto bad;
        return (Utf8Dec){cp, 3};
    }
    if ((c & 0xF8u) == 0xF0u) {
        uint32_t b1 = p[1];
        if (!CONT(b1)) goto bad;
        uint32_t b2 = p[2];
        if (!CONT(b2)) goto bad;
        uint32_t b3 = p[3];
        if (!CONT(b3)) goto bad;
        uint32_t cp = ((c & 0x07u) << 18) | ((b1 & 0x3Fu) << 12) | ((b2 & 0x3Fu) << 6) | (b3 & 0x3Fu);
        if (cp < 0x10000 || cp > 0x10FFFF) goto bad;
        return (Utf8Dec){cp, 4};
    }
bad:
    return (Utf8Dec){0xFFFD, 1};
}

int64_t utf8_encode(uint32_t cp, uint8_t *buf)
{
    if (cp < 0x80) { buf[0] = (uint8_t)cp; return 1; }
    if (cp < 0x800) {
        buf[0] = (uint8_t)(0xC0 | (cp >> 6));
        buf[1] = (uint8_t)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp >= 0x10000 && cp > 0x10FFFF) cp = 0xFFFD;
    if (cp < 0x10000) {
        buf[0] = (uint8_t)(0xE0 | (cp >> 12));
        buf[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = (uint8_t)(0x80 | (cp & 0x3F));
        return 3;
    }
    buf[0] = (uint8_t)(0xF0 | (cp >> 18));
    buf[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = (uint8_t)(0x80 | (cp & 0x3F));
    return 4;
}

int32_t utf8_char_width(uint32_t cp)
{
    if (cp < 0x20) return 0;
    if (cp < 0x7F) return 1;
    if (cp < 0xA0) return 0;
    if (cp >= 0x0300 && cp <= 0x036F) return 0;
    if (cp >= 0xFE00 && cp <= 0xFE0F) return 0;
    if ((cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0xA4CF) ||
        (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF) ||
        (cp >= 0xFF00 && cp <= 0xFF60) || (cp >= 0x1F300 && cp <= 0x1FAFF) ||
        (cp >= 0x20000 && cp <= 0x2FFFD))
        return 2;
    return 1;
}

int32_t utf8_display_width(const uint8_t *s)
{
    int32_t w = 0;
    if (!s) return 0;
    for (;;) {
        Utf8Dec d = utf8_decode(s);
        if (d.len == 0) break;
        s += d.len;
        w += utf8_char_width((uint32_t)d.cp);
    }
    return w;
}
