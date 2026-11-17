/* src/fs/img_tga.c - Truevision TGA decoder (freestanding C23; replaces img_tga.s).
 * Color-mapped (1/9), true-color (2/10) and gray (3/11) images, raw or RLE, 8/15/16/24/32-bit pixels, bottom-left or
 * top-left origin. Pixels that fall outside the image (an RLE run past the end) are dropped. */
#include "duop_img.h"

typedef struct {
    uint32_t w, h, bpp;                         /* bpp: bytes per stored pixel (1..4) */
    uint32_t type, rle, top;                    /* type: 1 cmap, 2 true color, 3 gray (RLE flag stripped) */
    uint32_t cmape, cmapn;                      /* color map entry bytes / entries */
    const uint8_t *cmap, *end;
    uint32_t *px;
} Tga;

/* first pixel byte, or nullptr when the variant is unsupported */
static const uint8_t *tga_header(Tga *c, const uint8_t *d)
{
    uint32_t t = d[2];
    c->type = t & 7;
    c->rle = t >> 3 & 1;
    if (c->type < 1 || c->type > 3) return nullptr;
    c->w = load_le16(d + 12);
    c->h = load_le16(d + 14);
    c->bpp = ((uint32_t)d[16] + 7) >> 3;
    if (c->bpp < 1 || c->bpp > 4) return nullptr;
    c->top = d[17] >> 5 & 1;
    c->cmapn = load_le16(d + 5);
    c->cmape = ((uint32_t)d[7] + 7) >> 3;
    const uint8_t *p = c->cmap = d + d[0] + 18;
    if (d[1]) {                                 /* a color map is present */
        if (c->cmape < 1 || c->cmape > 4 || !c->cmapn) return nullptr;
        p += (uint32_t)(c->cmapn * c->cmape);
    } else if (c->type == 1) {
        return nullptr;
    }
    return p < c->end ? p : nullptr;
}

/* RGBA from `bytes` stored bytes at p: gray, ARGB1555 or BGR(A) */
static uint32_t tga_decode_px(const uint8_t *p, uint32_t bytes)
{
    if (bytes == 1) return 0xFF000000u | (uint32_t)p[0] * 0x010101u;
    if (bytes == 2) {
        uint32_t v = load_le16(p);
        uint32_t r = (v >> 10 & 31) * 255 / 31, g = (v >> 5 & 31) * 255 / 31, b = (v & 31) * 255 / 31;
        return 0xFF000000u | b << 16 | g << 8 | r;
    }
    return (bytes == 4 ? (uint32_t)p[3] : 0xFFu) << 24 | (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2];
}

static uint32_t tga_color(const Tga *c, const uint8_t *p)
{
    if (c->type != 1) return tga_decode_px(p, c->bpp);
    uint32_t idx = c->bpp == 2 ? load_le16(p) : p[0];          /* color-mapped: index (8 or 16 bit) */
    if (idx >= c->cmapn) return 0xFF000000u;
    return tga_decode_px(c->cmap + (uint32_t)(idx * c->cmape), c->cmape);
}

static void tga_put(Tga *c, uint32_t index, uint32_t rgba)       /* honours the image origin */
{
    uint32_t row = index / c->w, col = index % c->w;
    if (!c->top) row = c->h - row - 1;
    if (row < c->h) c->px[row * c->w + col] = rgba;
}

/* one raw or run packet of `count` pixels; the new cursor, or nullptr when the data ran out */
static const uint8_t *tga_packet(Tga *c, const uint8_t *p, uint32_t index, bool repeat, uint32_t count)
{
    for (; count; count--, index++) {
        if ((size_t)(c->end - p) < c->bpp) return nullptr;
        tga_put(c, index, tga_color(c, p));
        if (!repeat) p += c->bpp;                                  /* raw packet: next stored pixel */
    }
    return repeat ? p + c->bpp : p;                                /* a run packet consumed one stored pixel */
}

int img_tga_decode(const uint8_t *d, size_t n, Image *out)
{
    Tga c = {0};
    if (n < 18) return IMG_E_UNSUP;
    c.end = d + n;
    const uint8_t *p = tga_header(&c, d);
    if (!p) return IMG_E_UNSUP;
    int rc = img_alloc(out, (int)c.w, (int)c.h);
    if (rc) return rc;
    c.px = (uint32_t *)out->px;
    uint32_t total = c.w * c.h;
    for (uint32_t i = 0; (int32_t)i < (int32_t)total;) {
        uint32_t count = 1;
        bool repeat = false;
        if (c.rle) {
            if (p >= c.end) break;
            uint32_t hdr = *p++;
            count = (hdr & 0x7F) + 1;
            repeat = hdr >> 7;
        }
        p = tga_packet(&c, p, i, repeat, count);
        if (!p) break;
        i += count;
    }
    return 0;
}
