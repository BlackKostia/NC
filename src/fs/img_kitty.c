/* src/fs/img_kitty.c - Kitty graphics protocol encoder (freestanding C23; replaces img_kitty.s).
 * RGBA8 picture -> "ESC _ G a=T,f=32,..." transmission split into base64 chunks of at most 4096 bytes (m=1 ... m=0),
 * cursor not moved (C=1), and the placement command used when the picture is only shown again. */
#include "duop_img.h"
#include "duop_string.h"

#define KITTY_RAW_CHUNK 3072                    /* -> 4096 base64 bytes */

static uint8_t *put_str(uint8_t *p, const char *s)
{
    while (*s) *p++ = (uint8_t)*s++;
    return p;
}

static uint8_t *put_num(uint8_t *p, uint32_t v)
{
    char t[24];
    size_t n = u64_to_dec(v, t);
    for (size_t i = 0; i < n; i++) *p++ = (uint8_t)t[i];
    return p;
}

size_t img_b64_encode(const uint8_t *src, size_t len, char *dst)
{
    static const char alpha[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    char *d = dst;
    for (size_t i = 0; i < len; i += 3) {
        size_t have = len - i < 3 ? len - i : 3;
        uint32_t v = (uint32_t)src[i] << 16 | (have > 1 ? (uint32_t)src[i + 1] << 8 : 0) | (have > 2 ? src[i + 2] : 0);
        for (int shift = 18; shift >= 0; shift -= 6) *d++ = alpha[v >> shift & 63];
        if (have < 3) d[-1] = '=';
        if (have < 2) d[-2] = '=';
    }
    return (size_t)(d - dst);
}

/* ESC _ G header of one chunk, ending in "m=<more>;" */
static uint8_t *kitty_header(uint8_t *p, int w, int h, int cols, bool first, bool more)
{
    if (first) {
        p = put_str(p, cols < 0 ? "\x1b_Ga=t,f=32,i=7,q=2,s=" : "\x1b_Ga=T,f=32,i=7,q=2,C=1,s=");
        p = put_num(p, (uint32_t)w);
        p = put_str(p, ",v=");
        p = put_num(p, (uint32_t)h);
        if (cols > 0) { p = put_str(p, ",c="); p = put_num(p, (uint32_t)cols); }
        p = put_str(p, ",m=");
    } else {
        p = put_str(p, "\x1b_Gm=");
    }
    *p++ = (uint8_t)('0' + more);
    *p++ = ';';
    return p;
}

size_t img_kitty_encode(const uint8_t *rgba, int w, int h, int cols, uint8_t *out, size_t cap)
{
    uint8_t *p = out, *end = out + cap;
    uint64_t left = (uint64_t)((uint32_t)w * (uint32_t)h) << 2;
    bool first = true;
    do {
        if ((size_t)(end - p) < 4096 + 128) return 0;
        size_t n = left < KITTY_RAW_CHUNK ? (size_t)left : KITTY_RAW_CHUNK;
        p = kitty_header(p, w, h, cols, first, left > n);
        p += img_b64_encode(rgba, n, (char *)p);
        *p++ = 0x1B;
        *p++ = '\\';
        rgba += n;
        left -= n;
        first = false;
    } while (left);
    return (size_t)(p - out);
}

size_t img_kitty_place(uint8_t *out, const int *rect, int cols, int rows)
{
    uint8_t *p = put_str(out, "\x1b_Ga=p,i=7,p=1,q=2,C=1,x=");
    static const char *const sep[] = {",y=", ",w=", ",h="};
    p = put_num(p, (uint32_t)rect[0]);
    for (int i = 1; i < 4; i++) { p = put_str(p, sep[i - 1]); p = put_num(p, (uint32_t)rect[i]); }
    p = put_str(p, ",c=");
    p = put_num(p, (uint32_t)cols);
    p = put_str(p, ",r=");
    p = put_num(p, (uint32_t)rows);
    *p++ = 0x1B;
    *p++ = '\\';
    return (size_t)(p - out);
}
