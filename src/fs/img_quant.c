/* src/fs/img_quant.c - adaptive palette quantizer for Sixel (freestanding C23; replaces img_quant.s).
 * Alpha is blended over the background, colors are binned to 15 bits (5-5-5) and the 255 most frequent bins (bin
 * means, not centres) become the palette; every other used bin maps to its nearest palette entry. */
#include "duop_img.h"
#include "duop_oop.h"

#define QB_N 32768
#define Q_MAXPAL 255

typedef struct {
    uint32_t cnt[QB_N], r[QB_N], g[QB_N], b[QB_N];     /* per-bin pixel count and channel sums (32-bit, wrapping) */
    uint8_t map[QB_N];                                 /* bin -> palette index */
} QWork;

/* 0x00RRGGBB of an RGBA pixel (R = low byte), alpha-blended over bg */
static uint32_t q_pixel(uint32_t px, uint32_t bg)
{
    uint32_t a = px >> 24;
    if (a == 255) return (px & 0xFF) << 16 | (px & 0xFF00) | (px >> 16 & 0xFF);
    uint32_t out = 0;
    for (int shift = 16; shift >= 0; shift -= 8, px >>= 8) {
        uint32_t v = (px & 0xFF) * a + (bg >> shift & 0xFF) * (255 - a);
        out |= (((v * 257 + 257) >> 16)) << shift;
    }
    return out;
}

static uint32_t q_bin(uint32_t rgb) { return (rgb >> 9 & 0x7C00) | (rgb >> 6 & 0x03E0) | (rgb >> 3 & 0x1F); }

static uint32_t q_bin_mean(const QWork *w, uint32_t bin, uint32_t count)
{
    return w->r[bin] / count << 16 | w->g[bin] / count << 8 | w->b[bin] / count;
}

static uint8_t q_nearest(const uint32_t *pal, uint32_t n, uint32_t rgb)
{
    uint32_t best = 0, best_d = 0xFFFFFFFFu;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t d = 0;
        for (int shift = 16; shift >= 0; shift -= 8) {
            int32_t diff = (int32_t)(pal[i] >> shift & 0xFF) - (int32_t)(rgb >> shift & 0xFF);
            d += (uint32_t)(diff * diff);
        }
        if (d < best_d) { best_d = d; best = i; }
    }
    return (uint8_t)best;
}

int img_quantize(const uint8_t *rgba, size_t n, uint32_t bg, uint8_t *idx, uint32_t *pal)
{
    QWork *w = mem_alloc(sizeof *w);
    if (!w) return 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t rgb = q_pixel(load_le32(rgba + 4 * i), bg), bin = q_bin(rgb);
        w->cnt[bin]++;
        w->r[bin] += rgb >> 16 & 0xFF;
        w->g[bin] += rgb >> 8 & 0xFF;
        w->b[bin] += rgb & 0xFF;
    }
    uint32_t size = 0;
    while (size < Q_MAXPAL) {                                  /* most frequent unpicked bin; the first of equals wins */
        uint32_t best = 0, at = 0;
        for (uint32_t bin = 0; bin < QB_N; bin++)
            if (w->cnt[bin] > best) { best = w->cnt[bin]; at = bin; }
        if (!best) break;                                      /* every used bin is in the palette */
        pal[size] = q_bin_mean(w, at, best);
        w->map[at] = (uint8_t)size++;
        w->cnt[at] = 0;                                        /* picked: out of the race */
    }
    for (uint32_t bin = 0; bin < QB_N; bin++)
        if (w->cnt[bin]) w->map[bin] = q_nearest(pal, size, q_bin_mean(w, bin, w->cnt[bin]));
    for (size_t i = 0; i < n; i++) idx[i] = w->map[q_bin(q_pixel(load_le32(rgba + 4 * i), bg))];
    mem_free(w);
    return (int)size;
}
