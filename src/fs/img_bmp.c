/* src/fs/img_bmp.c - BMP decoder (freestanding C23; replaces img_bmp.s).
 * OS/2 core and Windows DIB headers, 1/4/8-bit palettes, 16/32-bit BI_RGB and BI_BITFIELDS masks, 24-bit BGR;
 * bottom-up and top-down rows. A file that ends inside the raster keeps the rows decoded so far. */
#include "duop_img.h"

typedef struct {
    uint32_t w, h, bpp, stride, paln, pale;     /* pale: bytes per palette entry (3 OS/2, 4 Windows) */
    const uint8_t *pal, *data;
    uint32_t mask[4];                           /* r, g, b, a */
    bool top;                                   /* rows are stored top-down */
    uint32_t comp;
} Bmp;

/* fills c from the headers; 0 or IMG_E_* */
static int bmp_header(Bmp *c, const uint8_t *d, size_t n)
{
    if (n < 26) return IMG_E_FORMAT;
    uint32_t off = load_le32(d + 10);
    if (off >= n) return IMG_E_FORMAT;
    c->data = d + off;
    uint32_t hsz = load_le32(d + 14);
    c->pale = 4;
    if (hsz == 12) {
        c->w = load_le16(d + 18);
        c->h = load_le16(d + 20);
        c->bpp = load_le16(d + 24);
        c->pale = 3;
    } else {
        if (hsz < 40 || n < 54 || (uint64_t)hsz + 14 > n) return IMG_E_FORMAT;
        c->w = load_le32(d + 18);
        c->h = load_le32(d + 22);
        if ((int32_t)c->h < 0) { c->h = -c->h; c->top = true; }
        c->bpp = load_le16(d + 28);
        c->comp = load_le32(d + 30);
        c->paln = load_le32(d + 46);
    }
    c->pal = d + hsz + 14;                      /* the palette follows the header */
    if (c->comp == 3) {                         /* BI_BITFIELDS */
        if (c->bpp != 16 && c->bpp != 32) return IMG_E_UNSUP;
        if (n < 66 || (hsz >= 56 && n < 70)) return IMG_E_UNSUP;
        c->mask[0] = load_le32(d + 54);
        c->mask[1] = load_le32(d + 58);
        c->mask[2] = load_le32(d + 62);
        if (hsz >= 56) c->mask[3] = load_le32(d + 66);
        if (hsz == 40) c->pal += 12;            /* the masks sit between the header and the palette */
    } else if (c->comp == 0) {
        c->mask[0] = 0x7C00; c->mask[1] = 0x03E0; c->mask[2] = 0x001F;                 /* 16-bit BI_RGB = X1R5G5B5 */
        if (c->bpp == 32) { c->mask[0] = 0xFF0000; c->mask[1] = 0xFF00; c->mask[2] = 0xFF; }   /* X8R8G8B8, alpha ignored */
    } else {
        return IMG_E_UNSUP;
    }
    if (c->bpp > 32 || (c->bpp != 32 && !(0x01010112u >> c->bpp & 1))) return IMG_E_UNSUP;   /* 1, 4, 8, 16, 24, 32 */
    c->stride = ((c->w * c->bpp + 31) >> 5) << 2;
    if (c->bpp <= 8) {
        if (!c->paln) c->paln = 1u << c->bpp;
        /* palette entries must lie inside the file: bmp_pixel trusts the count it is given */
        uint64_t left = c->pal < d + n ? (uint64_t)(d + n - c->pal) : 0;
        uint64_t fit = left / c->pale;
        if (fit <= 0xFFFFFFFFu && (uint32_t)fit < c->paln) c->paln = (uint32_t)fit;
    }
    return 0;
}

/* one channel of v under mask, scaled to 8 bits */
static uint32_t bmp_extract(uint32_t v, uint32_t mask)
{
    uint32_t shift = (uint32_t)__builtin_ctz(mask), bits = 31u - (uint32_t)__builtin_clz(mask) - shift + 1;
    uint32_t x = (v & mask) >> shift;
    if (bits >= 8) return x >> (bits - 8);
    return x * 255 / ((1u << bits) - 1);
}

static uint32_t bmp_masked(const Bmp *c, uint32_t v)       /* A<<24 | B<<16 | G<<8 | R */
{
    uint32_t out = 0;
    for (int ch = 3; ch >= 0; ch--) out = out << 8 | (c->mask[ch] ? bmp_extract(v, c->mask[ch]) : 0xFFu);
    return out;
}

static uint32_t bmp_bgr(const uint8_t *p) { return 0xFF000000u | (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2]; }

static uint32_t bmp_pixel(const Bmp *c, const uint8_t *row, uint32_t x)
{
    switch (c->bpp) {
    case 24: return bmp_bgr(row + 3 * (size_t)x);
    case 16: return bmp_masked(c, load_le16(row + 2 * (size_t)x));
    case 32: return bmp_masked(c, load_le32(row + 4 * (size_t)x));
    default: {                                  /* 1/4/8-bit palette index */
        uint32_t bit = x * c->bpp, shift = 8 - (bit & 7) - c->bpp;
        uint32_t idx = (uint32_t)(row[bit >> 3] >> shift) & ((1u << c->bpp) - 1);
        if (idx >= c->paln) return 0xFF000000u;
        return bmp_bgr(c->pal + (size_t)idx * c->pale);
    }
    }
}

int img_bmp_decode(const uint8_t *d, size_t n, Image *out)
{
    Bmp c = {0};
    int rc = bmp_header(&c, d, n);
    if (rc) return rc;
    rc = img_alloc(out, (int)c.w, (int)c.h);
    if (rc) return rc;
    const uint8_t *end = d + n;
    uint32_t *dst = (uint32_t *)out->px;
    for (uint32_t y = 0; y < (uint32_t)(int32_t)c.h; y++) {
        uint32_t src_row = c.top ? y : c.h - y - 1;
        const uint8_t *row = c.data + (uint32_t)(src_row * c.stride);
        if (row + c.stride > end) break;                      /* truncated file: keep the decoded rows */
        uint32_t *line = dst + (uint32_t)(y * c.w);
        for (uint32_t x = 0; x < c.w; x++) line[x] = bmp_pixel(&c, row, x);
    }
    return 0;
}
