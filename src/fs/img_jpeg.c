/* src/fs/img_jpeg.c - baseline JPEG decoder (freestanding C23; replaces img_jpeg*.s).
 *
 * Marker layer (SOI..EOI walk, DQT, DHT with canonical tables + an 8-bit lookup, SOF0/SOF1, DRI, SOS), MSB-first bit
 * reader with 0xFF00 unstuffing that feeds zeros after the next marker, interleaved and single-component scans with
 * restart intervals, DC prediction + AC run-length decoding with dequantization, a separable 12-bit fixed-point IDCT
 * with 64-bit accumulators, and YCbCr / gray -> RGBA with nearest upsampling. Progressive, arithmetic, lossless and
 * CMYK files are IMG_E_UNSUP. A damaged scan keeps what was decoded (the rest of the planes stays zero). */
#include "duop_img.h"
#include "duop_oop.h"

typedef struct {
    uint16_t look[256];                         /* len << 8 | symbol for codes of up to 8 bits (0 = longer / unused) */
    int32_t maxcode[18], valptr[17], mincode[17];   /* canonical decode, index = code length (1..16), [17] = sentinel */
    uint8_t vals[256];
} Huff;

typedef struct {
    uint32_t id, h, v, tq, td, ta;
    int32_t pred;                               /* DC predictor */
    uint32_t bw, bh, sx, sy;                    /* MCU-padded plane size; upsampling shifts */
    uint8_t *plane;
} Comp;

typedef struct {
    uint16_t qt[4][64];                         /* quantizers in zigzag order */
    Huff huff[8];                               /* 0..3 DC, 4..7 AC */
    Comp comp[4];
    int32_t blk[64], tmp[64];                   /* coefficients (natural order), IDCT row pass */
    const uint8_t *p, *end;                     /* entropy reader */
    uint64_t bits;
    int32_t nbits;
    bool marker;                                /* a marker stopped the reader */
    uint32_t ncomp, w, h, hmax, vmax, mcux, mcuy, rst;
    uint32_t sncomp, scomp[4], todo;
    bool frame;                                 /* after SOF0/1 */
    Image *out;
} Jpeg;

/* ---- Huffman tables ---- */
/* fills look[] for the code of length l (<= 8); false when the code space is over-subscribed */
static bool huff_lookup(Huff *t, uint32_t code, uint32_t l, uint8_t sym)
{
    uint32_t start = code << (8 - l), run = 1u << (8 - l);
    if (start + run > 256) return false;
    for (uint32_t i = 0; i < run; i++) t->look[start + i] = (uint16_t)(l << 8 | sym);
    return true;
}

/* counts[16] then symbols; the number of symbols, or -1 */
static int huff_build(Huff *t, const uint8_t *counts)
{
    __builtin_memset(t->look, 0, sizeof t->look);
    uint32_t code = 0, k = 0;
    for (uint32_t l = 1; l <= 16; l++, code <<= 1) {
        uint32_t n = counts[l - 1];
        t->valptr[l] = (int32_t)k;
        t->mincode[l] = (int32_t)code;
        t->maxcode[l] = -1;
        if (!n) continue;
        t->maxcode[l] = (int32_t)(code + n - 1);
        for (; n; n--, code++, k++) {
            if (k >= 256) goto end;
            t->vals[k] = counts[16 + k];
            if (l <= 8 && !huff_lookup(t, code, l, t->vals[k])) return -1;
        }
    }
end:
    t->maxcode[17] = 0x7FFFFFFF;
    return (int)k;
}

/* ---- bit reader ---- */
static void bits_fill(Jpeg *j)                  /* top up to more than 56 bits; zeros once a marker is reached */
{
    while (j->nbits <= 56) {
        uint32_t b = 0;
        if (!j->marker) {
            if (j->p >= j->end) j->marker = true;
            else if (*j->p != 0xFF) b = *j->p++;
            else if (j->p + 1 >= j->end || j->p[1] != 0) j->marker = true;     /* a real marker: stay on it */
            else { b = 0xFF; j->p += 2; }
        }
        j->bits = j->bits << 8 | b;
        j->nbits += 8;
    }
}

static uint32_t bits_get(Jpeg *j, uint32_t n)                  /* n in 1..16 */
{
    if (j->nbits < (int32_t)n) bits_fill(j);
    j->nbits -= (int32_t)n;
    return (uint32_t)(j->bits >> j->nbits) & ((1u << n) - 1);
}

static int32_t bits_extend(Jpeg *j, uint32_t s)                 /* s bits as a signed JPEG magnitude */
{
    if (!s) return 0;
    int32_t v = (int32_t)bits_get(j, s);
    return v < (int32_t)(1u << (s - 1)) ? v - (int32_t)(1u << s) + 1 : v;
}

static uint32_t huff_decode(Jpeg *j, const Huff *t)
{
    if (j->nbits < 16) bits_fill(j);
    uint32_t e = t->look[(uint8_t)(j->bits >> (j->nbits - 8))];
    if (e) {
        j->nbits -= (int32_t)(e >> 8);
        return e & 0xFF;
    }
    for (uint32_t l = 9; l <= 16; l++) {                         /* canonical decode, code lengths 9..16 */
        int32_t code = (int32_t)((uint32_t)(j->bits >> (j->nbits - (int32_t)l)) & ((1u << l) - 1));
        if (code <= t->maxcode[l]) {
            j->nbits -= (int32_t)l;
            return t->vals[(uint32_t)(code - t->mincode[l] + t->valptr[l]) & 0xFF];
        }
    }
    return 0;
}

/* ---- IDCT: idct_t[x][u] = round(4096 * c(u) * cos((2x + 1) * u * pi / 16)), c(0) = 1 / (2 sqrt 2), c(u) = 1 / 2 ---- */
static const int32_t idct_t[8][8] = {
    {1448, 2009, 1892, 1703, 1448, 1138, 784, 400},   {1448, 1703, 784, -400, -1448, -2009, -1892, -1138},
    {1448, 1138, -784, -2009, -1448, 400, 1892, 1703}, {1448, 400, -1892, -1138, 1448, 1703, -784, -2009},
    {1448, -400, -1892, 1138, 1448, -1703, -784, 2009}, {1448, -1138, -784, 2009, -1448, -400, 1892, -1703},
    {1448, -1703, 784, 400, -1448, 2009, -1892, 1138}, {1448, -2009, 1892, -1703, 1448, -1138, 784, -400},
};

/* j->blk -> the plane block (bx, by); blocks outside the plane are dropped */
static void idct_store(Jpeg *j, const Comp *c, uint32_t bx, uint32_t by)
{
    for (int v = 0; v < 8; v++) {                                /* tmp[v][x] = sum_u blk[v][u] T[x][u] >> 8 */
        const int32_t *row = j->blk + v * 8;
        for (int x = 0; x < 8; x++) {
            int64_t acc = 0;
            for (int u = 0; u < 8; u++) acc += (int64_t)row[u] * idct_t[x][u];
            j->tmp[v * 8 + x] = (int32_t)((acc + 128) >> 8);
        }
    }
    if ((bx + 1) * 8 > c->bw || (by + 1) * 8 > c->bh) return;
    uint8_t *dst = c->plane + (uint32_t)(by * 8 * c->bw + bx * 8);
    for (int y = 0; y < 8; y++, dst += c->bw) {                  /* out[y][x] = clamp(sum_v tmp[v][x] T[y][v] >> 16, +128) */
        for (int x = 0; x < 8; x++) {
            int64_t acc = 0;
            for (int v = 0; v < 8; v++) acc += (int64_t)j->tmp[v * 8 + x] * idct_t[y][v];
            int64_t px = ((acc + 32768) >> 16) + 128;
            dst[x] = (uint8_t)(px < 0 ? 0 : px > 255 ? 255 : px);
        }
    }
}

/* ---- scan: blocks, MCUs, restarts ---- */
static const uint8_t zigzag[64] = {
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

static void scan_block(Jpeg *j, Comp *c)                          /* decode + dequantize one 8x8 block into j->blk */
{
    __builtin_memset(j->blk, 0, sizeof j->blk);
    const uint16_t *q = j->qt[c->tq];
    uint32_t s = huff_decode(j, &j->huff[c->td]);
    if (s > 15) return;
    c->pred += bits_extend(j, s);
    j->blk[0] = (int32_t)((uint32_t)c->pred * q[0]);
    const Huff *ac = &j->huff[c->ta + 4];
    for (uint32_t k = 1; k < 64;) {
        uint32_t rs = huff_decode(j, ac), run = rs >> 4, size = rs & 15;
        if (!size) {
            if (run != 15) return;                                 /* EOB */
            k += 16;
            continue;
        }
        k += run;
        if (k > 63) return;
        j->blk[zigzag[k]] = (int32_t)((uint32_t)bits_extend(j, size) * q[k]);
        k++;
    }
}

static void scan_restart(Jpeg *j)                                  /* skip the RSTn marker every j->rst MCUs */
{
    if (!j->rst) return;
    if (!j->todo) {
        j->todo = j->rst;
        j->bits = 0;
        j->nbits = 0;
        j->marker = false;
        const uint8_t *p = j->p;
        while (p + 1 < j->end) {
            if (p[0] == 0xFF && (p[1] & 0xF8) == 0xD0) { p += 2; break; }
            p++;
        }
        j->p = p;
        for (int i = 0; i < 4; i++) j->comp[i].pred = 0;
    }
    j->todo--;
}

static uint32_t blocks_span(uint32_t size, uint32_t factor, uint32_t max) { return ((size * factor + max - 1) / max + 7) >> 3; }

static void scan_all(Jpeg *j)
{
    if (j->sncomp == 1) {                                          /* non-interleaved: one block per MCU */
        Comp *c = &j->comp[j->scomp[0]];
        uint32_t cols = blocks_span(j->w, c->h, j->hmax), rows = blocks_span(j->h, c->v, j->vmax);
        for (uint32_t by = 0; by < rows; by++)
            for (uint32_t bx = 0; bx < cols; bx++) {
                scan_restart(j);
                scan_block(j, c);
                idct_store(j, c, bx, by);
            }
        return;
    }
    for (uint32_t my = 0; my < j->mcuy; my++)
        for (uint32_t mx = 0; mx < j->mcux; mx++) {
            scan_restart(j);
            for (uint32_t s = 0; s < j->sncomp; s++) {
                Comp *c = &j->comp[j->scomp[s]];
                for (uint32_t v = 0; v < c->v; v++)
                    for (uint32_t h = 0; h < c->h; h++) {
                        scan_block(j, c);
                        idct_store(j, c, mx * c->h + h, my * c->v + v);
                    }
            }
        }
}

/* ---- planes -> RGBA ---- */
static int32_t clamp8(int32_t v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

static void color_convert(Jpeg *j)
{
    uint32_t *dst = (uint32_t *)j->out->px;
    for (uint32_t y = 0; y < j->h; y++, dst += j->w) {
        const uint8_t *row[3] = {nullptr, nullptr, nullptr};
        for (uint32_t i = 0; i < j->ncomp; i++) row[i] = j->comp[i].plane + (uint32_t)((y >> j->comp[i].sy) * j->comp[i].bw);
        for (uint32_t x = 0; x < j->w; x++) {
            int32_t Y = row[0][x >> j->comp[0].sx];
            if (j->ncomp == 1) { dst[x] = 0xFF000000u | (uint32_t)Y * 0x010101u; continue; }
            int32_t cb = row[1][x >> j->comp[1].sx] - 128, cr = row[2][x >> j->comp[2].sx] - 128;
            int32_t r = clamp8(((cr * 91881 + 32768) >> 16) + Y);
            int32_t g = clamp8(((cb * -22554 + cr * -46802 + 32768) >> 16) + Y);
            int32_t b = clamp8(((cb * 116130 + 32768) >> 16) + Y);
            dst[x] = 0xFF000000u | (uint32_t)b << 16 | (uint32_t)g << 8 | (uint32_t)r;
        }
    }
}

/* ---- segments ---- */
static int seg_dqt(Jpeg *j, const uint8_t *p, size_t len)
{
    const uint8_t *end = p + len;
    while (p < end) {
        uint32_t pq = *p >> 4, tq = *p & 3;
        p++;
        size_t need = pq ? 128 : 64;
        if ((size_t)(end - p) < need) return IMG_E_CORRUPT;
        for (int i = 0; i < 64; i++) {
            uint32_t v = *p++;
            if (pq) v = v << 8 | *p++;
            j->qt[tq][i] = (uint16_t)v;
        }
    }
    return 0;
}

static int seg_dht(Jpeg *j, const uint8_t *p, size_t len)
{
    const uint8_t *end = p + len;
    while (end - p >= 17) {
        uint32_t sum = 0;
        for (int i = 1; i <= 16; i++) sum += p[i];
        if (sum > 256 || (size_t)(end - p) < sum + 17) return IMG_E_CORRUPT;
        int n = huff_build(&j->huff[(p[0] >> 4 & 1) * 4 + (p[0] & 3)], p + 1);
        if (n < 0) return IMG_E_CORRUPT;
        p += (size_t)n + 17;
    }
    return p == end ? 0 : IMG_E_CORRUPT;
}

static uint32_t log2_ratio(uint32_t max, uint32_t f, bool *ok)     /* log2(max / f): only power-of-two ratios */
{
    uint32_t q = max / f;
    *ok = !(max % f) && q && !(q & (q - 1));
    return (uint32_t)__builtin_ctz(q | 1u << 31);
}

static int sof_planes(Jpeg *j)
{
    j->mcux = (j->w + 8 * j->hmax - 1) / (8 * j->hmax);
    j->mcuy = (j->h + 8 * j->vmax - 1) / (8 * j->vmax);
    for (uint32_t i = 0; i < j->ncomp; i++) {
        Comp *c = &j->comp[i];
        bool okx, oky;
        c->sx = log2_ratio(j->hmax, c->h, &okx);
        c->sy = log2_ratio(j->vmax, c->v, &oky);
        if (!okx || !oky) return IMG_E_UNSUP;
        c->bw = j->mcux * c->h * 8;
        c->bh = j->mcuy * c->v * 8;
        if ((uint64_t)c->bw * c->bh > IMG_MAX_PIXELS) return IMG_E_UNSUP;
        c->plane = mem_alloc((size_t)c->bw * c->bh);
        if (!c->plane) return IMG_E_NOMEM;
    }
    return 0;
}

static void free_planes(Jpeg *j)
{
    for (int i = 0; i < 4; i++) { mem_free(j->comp[i].plane); j->comp[i].plane = nullptr; }
}

static int seg_sof(Jpeg *j, const uint8_t *s, size_t len)
{
    if (j->frame) {                                                /* a second frame replaces the first */
        free_planes(j);
        img_free(j->out);
        j->frame = false;
    }
    if (len < 6) return IMG_E_CORRUPT;
    if (s[0] != 8 || (s[5] != 1 && s[5] != 3)) return IMG_E_UNSUP;   /* 8-bit samples; gray or YCbCr */
    j->ncomp = s[5];
    if (len < 3 * j->ncomp + 6) return IMG_E_CORRUPT;
    j->h = (uint32_t)s[1] << 8 | s[2];
    if (!j->h || j->h > IMG_MAX_DIM) return IMG_E_CORRUPT;
    j->w = (uint32_t)s[3] << 8 | s[4];
    if (!j->w || j->w > IMG_MAX_DIM) return IMG_E_CORRUPT;
    j->hmax = j->vmax = 1;
    for (uint32_t i = 0; i < j->ncomp; i++) {
        const uint8_t *e = s + 6 + 3 * i;
        Comp *c = &j->comp[i];
        c->id = e[0];
        c->h = e[1] >> 4;
        c->v = e[1] & 15;
        if (!c->h || !c->v || c->h > 4 || c->v > 4) return IMG_E_CORRUPT;
        if (c->h > j->hmax) j->hmax = c->h;
        if (c->v > j->vmax) j->vmax = c->v;
        c->tq = e[2] & 3;
    }
    int rc = sof_planes(j);
    if (!rc) rc = img_alloc(j->out, (int)j->w, (int)j->h);
    j->frame = !rc;
    return rc;
}

/* SOS header, then the entropy-coded data behind it; *resume = where the scan stopped */
static int seg_sos(Jpeg *j, const uint8_t *s, size_t len, const uint8_t **resume)
{
    if (!j->frame || !s[0] || s[0] > 4 || len < 2u * s[0] + 4) return IMG_E_CORRUPT;
    j->sncomp = s[0];
    for (uint32_t i = 0; i < j->sncomp; i++) {
        uint32_t k = 0;
        while (k < j->ncomp && j->comp[k].id != s[1 + 2 * i]) k++;
        if (k == j->ncomp) return IMG_E_CORRUPT;
        j->scomp[i] = k;
        j->comp[k].td = s[2 + 2 * i] >> 4 & 3;
        j->comp[k].ta = s[2 + 2 * i] & 3;
        j->comp[k].pred = 0;
    }
    j->p = s + len;
    j->bits = 0;
    j->nbits = 0;
    j->marker = false;
    j->todo = j->rst;
    scan_all(j);
    *resume = j->p;
    return 0;
}

static int jpeg_segment(Jpeg *j, const uint8_t *s, size_t len, uint32_t marker, const uint8_t **resume)
{
    *resume = nullptr;
    switch (marker) {
    case 0xDB: return seg_dqt(j, s, len);
    case 0xC4: return seg_dht(j, s, len);
    case 0xC0: case 0xC1: return seg_sof(j, s, len);
    case 0xDD:
        if (len < 2) return IMG_E_CORRUPT;
        j->rst = (uint32_t)s[0] << 8 | s[1];
        return 0;
    case 0xDA: return seg_sos(j, s, len, resume);
    default: return (marker & 0xF0) == 0xC0 ? IMG_E_UNSUP : 0;       /* progressive, lossless, arithmetic ... */
    }
}

static int jpeg_markers(Jpeg *j, const uint8_t *p, const uint8_t *end)
{
    j->end = end;
    for (;;) {
        while (p < end && *p != 0xFF) p++;
        if (p >= end) return 0;
        uint32_t m;
        do {
            if (++p >= end) return 0;
            m = *p;
        } while (m == 0xFF);                                       /* fill bytes */
        p++;
        if (m == 0xD9) return 0;                                   /* EOI */
        if (m == 0xD8 || (m & 0xF8) == 0xD0) continue;             /* SOI, stray RSTn */
        if (end - p < 2) return 0;
        size_t len = (size_t)p[0] << 8 | p[1];
        if (len < 2 || len > (size_t)(end - p)) return IMG_E_CORRUPT;
        const uint8_t *resume;
        int rc = jpeg_segment(j, p + 2, len - 2, m, &resume);
        if (rc) return rc;
        p = resume ? resume : p + len;
    }
}

int img_jpeg_decode(const uint8_t *d, size_t n, Image *out)
{
    Jpeg *j = mem_alloc(sizeof *j);
    if (!j) return IMG_E_NOMEM;
    j->out = out;
    int rc = n >= 2 ? jpeg_markers(j, d + 2, d + n) : 0;
    if (!rc) {
        rc = IMG_E_CORRUPT;
        if (j->frame) { color_convert(j); rc = 0; }
    }
    free_planes(j);
    mem_free(j);
    return rc;
}
