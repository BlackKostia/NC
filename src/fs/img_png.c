/* src/fs/img_png.c - PNG decoder (freestanding C23; replaces img_png.s and img_png_px.s).
 * IHDR validation, PLTE/tRNS/IDAT collection, zlib inflate, the plain / Adam7 pass schedule, scanline unfiltering
 * (None/Sub/Up/Average/Paeth) and every color type / bit depth (1..16, palette + tRNS, gray/RGB color keys) to RGBA8.
 * A truncated file or stream keeps the rows that were decoded (the rest of the raw data is zero). */
#include "duop_img.h"
#include "duop_inflate.h"
#include "duop_oop.h"

typedef struct {
    uint32_t w, h, depth, ctype, ch, bits, fbpp, ilace;
    const uint8_t *plte, *trns;
    uint32_t plte_n, trns_n;
    uint8_t *idat, *raw;
    size_t idat_n, raw_n;
    uint32_t *px;
} Png;

typedef struct { uint32_t x0, y0, dx, dy, pw, ph; } PngPass;

static const uint8_t adam7[7][4] = {{0, 0, 8, 8}, {4, 0, 8, 8}, {0, 4, 4, 8}, {2, 0, 4, 4}, {0, 2, 2, 4}, {1, 0, 2, 2}, {0, 1, 1, 2}};

static int png_parse_ihdr(Png *c, const uint8_t *d, size_t n)
{
    if (n < 33 || load_le32(d + 12) != 0x52444849) return IMG_E_FORMAT;          /* "IHDR" */
    c->w = __builtin_bswap32(load_le32(d + 16));
    if (!c->w || c->w > IMG_MAX_DIM) return IMG_E_CORRUPT;
    c->h = __builtin_bswap32(load_le32(d + 20));
    if (!c->h || c->h > IMG_MAX_DIM) return IMG_E_CORRUPT;
    if ((uint64_t)c->h * c->w > IMG_MAX_PIXELS) return IMG_E_UNSUP;
    c->depth = d[24];
    c->ctype = d[25];
    c->ilace = d[28];
    /* allowed bit depths per color type (bit d set = depth d valid) and samples per pixel */
    static const uint32_t depth_mask[7] = {0x10116, 0, 0x10100, 0x116, 0x10100, 0, 0x10100};
    static const uint8_t samples[7] = {1, 0, 3, 1, 2, 0, 4};
    if (c->ctype > 6 || c->depth > 16 || !(depth_mask[c->ctype] >> c->depth & 1) || c->ilace > 1) return IMG_E_UNSUP;
    c->ch = samples[c->ctype];
    c->bits = c->ch * c->depth;
    c->fbpp = c->bits >> 3 ? c->bits >> 3 : 1;
    return 0;
}

/* walks the chunk list, records PLTE/tRNS and returns the total IDAT bytes (copied to dst when not null) */
static size_t png_walk(Png *c, const uint8_t *d, size_t n, uint8_t *dst)
{
    size_t total = 0;
    for (size_t off = 8; off + 12 <= n;) {
        size_t len = __builtin_bswap32(load_le32(d + off));
        if (off + len + 12 > n) len = n - off - 12;                              /* truncated file: keep what is there */
        const uint8_t *pay = d + off + 8;
        uint32_t type = load_le32(d + off + 4);
        if (type == 0x54414449) {                                                 /* IDAT */
            if (dst) mem_copy(dst + total, pay, len);
            total += len;
        } else if (type == 0x45544C50) {                                          /* PLTE */
            c->plte = pay;
            c->plte_n = (uint32_t)len / 3;
        } else if (type == 0x534E5274) {                                          /* tRNS */
            c->trns = pay;
            c->trns_n = (uint32_t)len;
        } else if (type == 0x444E4549) {                                          /* IEND */
            break;
        }
        off += len + 12;
    }
    return total;
}

static void png_pass_geom(const Png *c, int pass, PngPass *p)                    /* pass -1 = the whole image */
{
    if (pass < 0) { *p = (PngPass){0, 0, 1, 1, c->w, c->h}; return; }
    p->x0 = adam7[pass][0]; p->y0 = adam7[pass][1]; p->dx = adam7[pass][2]; p->dy = adam7[pass][3];
    int32_t w = (int32_t)(c->w - p->x0), h = (int32_t)(c->h - p->y0);
    p->pw = w > 0 ? ((uint32_t)w + p->dx - 1) / p->dx : 0;
    p->ph = h > 0 ? ((uint32_t)h + p->dy - 1) / p->dy : 0;
}

static size_t png_row_bytes(const Png *c, uint32_t pw) { return ((size_t)pw * c->bits + 7) >> 3; }

static int png_inflate(Png *c)                                                   /* raw = inflate(IDAT), sized for all passes */
{
    size_t total = 0;
    for (int pass = c->ilace ? 0 : -1;; pass++) {
        PngPass p;
        png_pass_geom(c, pass, &p);
        if (p.pw) total += (png_row_bytes(c, p.pw) + 1) * p.ph;
        if (pass < 0 || pass == 6) break;
    }
    c->raw_n = total;
    c->raw = mem_alloc(total + 16);
    if (!c->raw) return IMG_E_NOMEM;
    return inflate_zlib(c->idat, c->idat_n, c->raw, total) > 0 ? 0 : IMG_E_CORRUPT;
}

static int paeth(int a, int b, int c)
{
    int p = a + b - c, pa = p > a ? p - a : a - p, pb = p > b ? p - b : b - p, pc = p > c ? p - c : c - p;
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

static void png_unfilter(uint8_t *cur, const uint8_t *prev, uint32_t n, uint32_t bpp, uint32_t ft)
{
    if (!ft) return;
    for (uint32_t k = 0; k < n; k++) {
        int a = 0, b = prev ? prev[k] : 0, c = 0;
        if (k >= bpp) { a = cur[k - bpp]; if (prev) c = prev[k - bpp]; }
        switch (ft) {
        case 1: cur[k] = (uint8_t)(cur[k] + a); break;
        case 2: cur[k] = (uint8_t)(cur[k] + b); break;
        case 3: cur[k] = (uint8_t)(cur[k] + ((a + b) >> 1)); break;
        case 4: cur[k] = (uint8_t)(cur[k] + paeth(a, b, c)); break;
        default: break;                                                           /* unknown filter: leave the byte as is */
        }
    }
}

static uint32_t png_palette(const Png *c, uint32_t idx)
{
    if (idx >= c->plte_n) return 0xFF000000u;
    const uint8_t *e = c->plte + 3 * (size_t)idx;
    uint32_t a = idx < c->trns_n ? c->trns[idx] : 0xFFu;
    return a << 24 | (uint32_t)e[2] << 16 | (uint32_t)e[1] << 8 | e[0];
}

static uint32_t png_gray(const Png *c, uint32_t raw, uint32_t g8)                  /* tRNS gray key makes the pixel clear */
{
    uint32_t a = 0xFF;
    if (c->trns_n >= 2 && ((uint32_t)c->trns[0] << 8 | c->trns[1]) == raw) a = 0;
    return a << 24 | g8 * 0x010101u;
}

static uint32_t png_sample(const uint8_t *p, uint32_t s) { return s == 2 ? (uint32_t)p[0] << 8 | p[1] : p[0]; }

static uint32_t png_pixel(const Png *c, const uint8_t *row, uint32_t i)
{
    uint32_t d = c->depth;
    if (d < 8) {                                                                   /* sub-byte sample */
        uint32_t bit = i * d, mask = (1u << d) - 1;
        uint32_t v = (uint32_t)(row[bit >> 3] >> (8 - (bit & 7) - d)) & mask;
        return c->ctype == 3 ? png_palette(c, v) : png_gray(c, v, v * 255 / mask);
    }
    uint32_t s = d == 16 ? 2 : 1;
    if (c->ctype == 3) return png_palette(c, row[i]);
    const uint8_t *p = row + (size_t)i * c->ch * s;
    switch (c->ctype) {
    case 0: return png_gray(c, png_sample(p, s), p[0]);                            /* g8 = the high byte */
    case 4: return (uint32_t)p[s] << 24 | p[0] * 0x010101u;
    default: {
        uint32_t a = c->ctype == 6 ? p[3 * s] : 0xFFu;
        if (c->ctype == 2 && c->trns_n >= 6) {                                     /* RGB color key */
            uint32_t ch = 0;
            while (ch < 3 && ((uint32_t)c->trns[2 * ch] << 8 | c->trns[2 * ch + 1]) == png_sample(p + ch * s, s)) ch++;
            if (ch == 3) a = 0;
        }
        return a << 24 | (uint32_t)p[2 * s] << 16 | (uint32_t)p[s] << 8 | p[0];
    }
    }
}

/* unfilters and converts one pass; returns the first byte behind its data */
static uint8_t *png_run_pass(Png *c, uint8_t *src, const PngPass *p)
{
    uint32_t rowbytes = (uint32_t)png_row_bytes(c, p->pw);
    const uint8_t *prev = nullptr;
    for (uint32_t r = 0; r < p->ph; r++, src += rowbytes + 1) {
        uint8_t *cur = src + 1;
        png_unfilter(cur, prev, rowbytes, c->fbpp, src[0]);
        uint32_t *line = c->px + (uint32_t)((p->y0 + r * p->dy) * c->w);
        for (uint32_t i = 0; i < p->pw; i++) line[p->x0 + i * p->dx] = png_pixel(c, cur, i);
        prev = cur;
    }
    return src;
}

int img_png_decode(const uint8_t *d, size_t n, Image *out)
{
    Png c = {0};
    int rc = png_parse_ihdr(&c, d, n);
    if (rc) return rc;
    c.idat_n = png_walk(&c, d, n, nullptr);
    if (!c.idat_n) return IMG_E_CORRUPT;
    c.idat = mem_alloc(c.idat_n);
    if (!c.idat) return IMG_E_NOMEM;
    png_walk(&c, d, n, c.idat);
    rc = png_inflate(&c);
    if (!rc) rc = img_alloc(out, (int)c.w, (int)c.h);
    if (!rc) {
        c.px = (uint32_t *)out->px;
        uint8_t *src = c.raw;
        for (int pass = c.ilace ? 0 : -1;; pass++) {
            PngPass p;
            png_pass_geom(&c, pass, &p);
            if (p.pw && p.ph) src = png_run_pass(&c, src, &p);
            if (pass < 0 || pass == 6) break;
        }
    }
    mem_free(c.idat);
    mem_free(c.raw);
    return rc;
}
