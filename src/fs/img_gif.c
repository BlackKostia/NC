/* src/fs/img_gif.c - GIF decoder (freestanding C23; replaces img_gif.s and img_gif_lzw.s).
 * First frame of GIF87a/89a: global/local palettes, graphic-control transparency, interlaced rows and variable-width
 * LZW (2..12 bits), drawn onto the logical screen. A broken or short LZW stream keeps the pixels decoded so far. */
#include "duop_img.h"
#include "duop_oop.h"

typedef struct {
    uint16_t prefix[4096];
    uint8_t suffix[4096];
    uint8_t stack[4097];
} GifTab;

typedef struct {
    const uint8_t *pal;                         /* RGB triples */
    uint32_t paln;
    int32_t trans;                              /* transparent index or -1 */
    uint32_t ix, iy, iw, ih;                    /* frame rectangle */
    bool lace;
    uint32_t c1, c2, c3;                        /* rows in interlace passes 1..3 */
    uint32_t pos;                               /* pixels emitted */
    uint32_t cw, ch;                            /* canvas */
    uint32_t *px;
    GifTab *tab;
} Gif;

/* the optional color table at p: records it and returns the cursor behind it */
static const uint8_t *gif_palette(Gif *g, const uint8_t *p, uint32_t flags)
{
    if (!(flags & 0x80)) return p;
    g->pal = p;
    g->paln = 2u << (flags & 7);
    return p + 3 * (size_t)g->paln;
}

/* payload of the sub-block chain at p (copied to dst when not null); *next = cursor after the terminator */
static size_t gif_subblocks(const uint8_t *p, const uint8_t *end, uint8_t *dst, const uint8_t **next)
{
    size_t total = 0;
    while (p < end) {
        size_t len = *p++;
        if (!len) break;
        if (len > (size_t)(end - p)) len = (size_t)(end - p);
        if (dst) mem_copy(dst + total, p, len);
        total += len;
        p += len;
    }
    *next = p;
    return total;
}

/* image row for sequential row r of an interlaced frame */
static uint32_t gif_lace_row(const Gif *g, uint32_t r)
{
    if (r < g->c1) return r << 3;
    r -= g->c1;
    if (r < g->c2) return r * 8 + 4;
    r -= g->c2;
    if (r < g->c3) return r * 4 + 2;
    return (r - g->c3) * 2 + 1;
}

/* next pixel of the frame: placement (interlace, clipping to the screen) and transparency */
static void gif_put(Gif *g, uint32_t index)
{
    uint32_t pos = g->pos++;
    if (!g->iw) return;
    uint32_t row = pos / g->iw, x = pos % g->iw;
    if (row >= g->ih) return;
    if (g->lace) row = gif_lace_row(g, row);
    row += g->iy;
    if (row >= g->ch) return;
    x += g->ix;
    if (x >= g->cw || index == (uint32_t)g->trans) return;
    uint32_t rgba = 0xFF000000u;
    if (index < g->paln) {
        const uint8_t *e = g->pal + 3 * (size_t)index;
        rgba |= (uint32_t)e[0] | (uint32_t)e[1] << 8 | (uint32_t)e[2] << 16;
    }
    g->px[row * g->cw + x] = rgba;
}

/* emits the string of `code`; returns its first (root) index */
static uint32_t gif_emit(Gif *g, uint32_t code, uint32_t clear)
{
    GifTab *t = g->tab;
    uint32_t depth = 0;
    while (code >= clear && depth < 4096) {
        t->stack[depth++] = t->suffix[code];
        code = t->prefix[code];
    }
    code &= 0xFFF;
    gif_put(g, code);
    while (depth) gif_put(g, t->stack[--depth]);
    return code;
}

typedef struct { const uint8_t *p, *end; uint64_t buf; uint32_t bits, size; } GifBits;

static int32_t gif_read_code(GifBits *b)                 /* -1 at the end of the data */
{
    while (b->bits < b->size) {
        if (b->p >= b->end) return -1;
        b->buf |= (uint64_t)*b->p++ << b->bits;
        b->bits += 8;
    }
    uint32_t code = (uint32_t)b->buf & ((1u << b->size) - 1);
    b->buf >>= b->size;
    b->bits -= b->size;
    return (int32_t)code;
}

/* decodes the LZW stream data[0..len) into the canvas */
static void gif_lzw(Gif *g, const uint8_t *data, size_t len, uint32_t mcs)
{
    if (mcs < 2 || mcs > 11) return;
    GifBits b = {.p = data, .end = data + len};
    uint32_t clear = 1u << mcs, next = clear + 2;
    int32_t old = -1, first = 0;
    b.size = mcs + 1;
    for (;;) {
        int32_t code = gif_read_code(&b);
        if (code < 0) return;
        if ((uint32_t)code == clear) { b.size = mcs + 1; next = clear + 2; old = -1; continue; }
        if ((uint32_t)code == clear + 1) return;                         /* end of information */
        if (old < 0) {                                                    /* first code after a clear: a root index */
            if ((uint32_t)code >= clear) return;
            old = first = code;
            gif_put(g, (uint32_t)code);
            continue;
        }
        if ((uint32_t)code > next) return;                               /* beyond the dictionary: corrupt stream */
        if ((uint32_t)code == next) {                                     /* KwKwK: string(old) + first(string(old)) */
            first = (int32_t)gif_emit(g, (uint32_t)old, clear);
            gif_put(g, (uint32_t)first);
        } else {
            first = (int32_t)gif_emit(g, (uint32_t)code, clear);
        }
        if (next < 4096) {
            g->tab->prefix[next] = (uint16_t)old;
            g->tab->suffix[next] = (uint8_t)first;
            next++;
            if (next == 1u << b.size && b.size < 12) b.size++;
        }
        old = code;
    }
}

static int gif_image(Gif *g, const uint8_t *p, const uint8_t *end)     /* p: after the 0x2C separator */
{
    if (end - p < 10) return IMG_E_CORRUPT;
    g->ix = load_le16(p); g->iy = load_le16(p + 2); g->iw = load_le16(p + 4); g->ih = load_le16(p + 6);
    uint32_t flags = p[8];
    g->lace = flags >> 6 & 1;
    p = gif_palette(g, p + 9, flags);                                    /* a local table overrides the global one */
    if (p >= end) return IMG_E_CORRUPT;
    uint32_t mcs = *p++;
    g->c1 = (g->ih + 7) >> 3;
    g->c2 = (g->ih + 3) >> 3;
    g->c3 = (g->ih + 1) >> 2;
    const uint8_t *next;
    size_t len = gif_subblocks(p, end, nullptr, &next);
    uint8_t *mem = mem_alloc(sizeof(GifTab) + len + 16);
    if (!mem) return IMG_E_NOMEM;
    g->tab = (GifTab *)mem;
    gif_subblocks(p, end, mem + sizeof(GifTab), &next);
    gif_lzw(g, mem + sizeof(GifTab), len, mcs);
    mem_free(mem);
    return 0;
}

/* extensions (graphic control transparency), then the first image */
static int gif_blocks(Gif *g, const uint8_t *p, const uint8_t *end)
{
    for (;;) {
        if (p >= end) return IMG_E_CORRUPT;
        uint32_t kind = *p++;
        if (kind == 0x2C) return gif_image(g, p, end);
        if (kind != 0x21 || end - p < 6) return IMG_E_CORRUPT;           /* trailer / garbage before any image */
        if (p[0] == 0xF9 && (p[2] & 1)) g->trans = p[5];
        const uint8_t *next;
        gif_subblocks(p + 1, end, nullptr, &next);
        p = next;
    }
}

int img_gif_decode(const uint8_t *d, size_t n, Image *out)
{
    Gif g = {.trans = -1};
    if (n < 13) return IMG_E_FORMAT;
    g.cw = load_le16(d + 6);
    g.ch = load_le16(d + 8);
    int rc = img_alloc(out, (int)g.cw, (int)g.ch);
    if (rc) return rc;
    g.px = (uint32_t *)out->px;
    const uint8_t *p = gif_palette(&g, d + 13, d[10]);                   /* global color table */
    return gif_blocks(&g, p, d + n);
}
