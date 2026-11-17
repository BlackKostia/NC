/* src/fs/img_sixel.c - DEC Sixel encoder (freestanding C23; replaces img_sixel.s).
 * RGBA8 -> adaptive palette (img_quantize) -> "ESC P q" raster with "#n;2;r;g;b" color registers and run-length
 * compressed six-pixel bands (only the colors used in a band are sent). Output overflow gives 0 bytes. */
#include "duop_img.h"
#include "duop_oop.h"
#include "duop_string.h"

typedef struct {
    const uint8_t *idx;                          /* palette index per pixel */
    uint32_t w, h, ncol;
    const uint8_t *end;                          /* end of the output buffer */
    uint32_t pal[256];
    uint8_t used[256];                           /* colors present in the current band */
} Six;

static uint8_t *put_num(uint8_t *p, uint32_t v)
{
    char t[24];
    size_t n = u64_to_dec(v, t);
    for (size_t i = 0; i < n; i++) *p++ = (uint8_t)t[i];
    return p;
}

static uint8_t *put_pct(uint8_t *p, uint32_t rgb, int shift) { return put_num(p, ((rgb >> shift & 0xFF) * 100 + 127) / 255); }

/* DCS, raster size and color registers; nullptr on overflow */
static uint8_t *six_header(const Six *c, uint8_t *p)
{
    if ((size_t)(c->end - p) < 64) return nullptr;
    for (const char *s = "\x1bPq\"1;1;"; *s; s++) *p++ = (uint8_t)*s;
    p = put_num(p, c->w);
    *p++ = ';';
    p = put_num(p, c->h);
    for (uint32_t i = 0; i < c->ncol; i++) {
        if ((size_t)(c->end - p) < 64) return nullptr;
        *p++ = '#';
        p = put_num(p, i);
        *p++ = ';'; *p++ = '2'; *p++ = ';';
        p = put_pct(p, c->pal[i], 16);
        *p++ = ';';
        p = put_pct(p, c->pal[i], 8);
        *p++ = ';';
        p = put_pct(p, c->pal[i], 0);
    }
    return p;
}

static uint8_t *six_run(uint8_t *p, uint32_t ch, uint32_t len)      /* "!n<c>" for runs of 4 or more */
{
    if (!len) return p;
    if (len <= 3) {
        while (len--) *p++ = (uint8_t)ch;
        return p;
    }
    *p++ = '!';
    p = put_num(p, len);
    *p++ = (uint8_t)ch;
    return p;
}

/* the sixels of one color over a band of `rows` rows */
static uint8_t *six_line(const Six *c, uint32_t y0, uint32_t rows, uint32_t color, uint8_t *p)
{
    const uint8_t *band = c->idx + (uint32_t)(y0 * c->w);
    uint32_t run_ch = 0xFFFFFFFFu, run_len = 0;
    for (uint32_t x = 0; x < c->w; x++) {
        uint32_t bits = 0;
        for (uint32_t k = 0; k < rows; k++)
            if (band[x + (size_t)k * c->w] == color) bits |= 1u << k;
        uint32_t ch = bits + 63;
        if (ch == run_ch) { run_len++; continue; }
        p = six_run(p, run_ch, run_len);
        run_ch = ch;
        run_len = 1;
    }
    return run_ch == 63 ? p : six_run(p, run_ch, run_len);          /* trailing empty sixels are implicit */
}

/* one six-row band; nullptr on overflow */
static uint8_t *six_band(Six *c, uint8_t *p, uint32_t y0)
{
    uint32_t rows = c->h - y0 > 6 ? 6 : c->h - y0;
    __builtin_memset(c->used, 0, sizeof c->used);
    const uint8_t *px = c->idx + (uint32_t)(y0 * c->w);
    for (uint32_t i = 0, n = rows * c->w; i < n; i++) c->used[px[i]] = 1;
    for (uint32_t color = 0; color < c->ncol; color++) {
        if (!c->used[color]) continue;
        if ((size_t)(c->end - p) < (size_t)c->w + 32) return nullptr;     /* room for this color line (worst case) */
        *p++ = '#';
        p = put_num(p, color);
        p = six_line(c, y0, rows, color, p);
        *p++ = '$';                                                       /* carriage return: the next color overprints */
    }
    if ((size_t)(c->end - p) < 64) return nullptr;
    *p++ = '-';                                                           /* next band */
    return p;
}

size_t img_sixel_encode(const uint8_t *rgba, int w, int h, uint32_t bg, uint8_t *out, size_t cap)
{
    if (w <= 0 || h <= 0 || w > IMG_MAX_DIM || h > IMG_MAX_DIM || (int64_t)w * h > IMG_MAX_PIXELS) return 0;
    uint8_t *idx = mem_alloc((size_t)w * (size_t)h);
    if (!idx) return 0;
    Six c = {.idx = idx, .w = (uint32_t)w, .h = (uint32_t)h, .end = out + cap};
    c.ncol = (uint32_t)img_quantize(rgba, (uint32_t)w * (uint32_t)h, bg, idx, c.pal);
    uint8_t *p = c.ncol ? six_header(&c, out) : nullptr;
    for (uint32_t y = 0; p && y < c.h; y += 6) p = six_band(&c, p, y);
    size_t result = 0;
    if (p) {
        *p++ = 0x1B;                                                      /* ESC \  (the bands left >= 64 bytes of slack) */
        *p++ = '\\';
        result = (size_t)(p - out);
    }
    mem_free(idx);
    return result;
}
