/* src/fs/img_pnm.c - Netpbm (binary P5 graymap / P6 pixmap, maxval up to 65535) and QOI decoders (freestanding C23;
 * replaces img_pnm.s). Both keep the pixels decoded so far when the data ends early. */
#include "duop_img.h"

/* next decimal number after blanks and # comments: its value, or -1 when there is none / it exceeds 2^31 - 1 */
static int64_t pnm_uint(const uint8_t **pp, const uint8_t *end)
{
    const uint8_t *p = *pp;
    int64_t v = -1;
    for (;;) {
        if (p >= end) goto out;
        uint32_t c = *p;
        if (c == '#') {
            while (p < end && *p++ != '\n') {}
        } else if (c > ' ') {
            break;
        } else {
            p++;
        }
    }
    v = 0;
    while (p < end) {
        uint32_t d = (uint32_t)*p - '0';
        if (d > 9) break;
        v = v * 10 + d;
        if (v > 0x7FFFFFFF) { v = -1; break; }
        p++;
    }
out:
    *pp = p;
    return v;
}

/* one pixel: samples scaled to 8 bits (a sample above maxval spills into the next channel, as the asm always did) */
static uint32_t pnm_pixel(const uint8_t *p, uint32_t channels, uint32_t bps, uint32_t maxval)
{
    uint32_t packed = 0;
    for (uint32_t ch = 0; ch < channels; ch++, p += bps) {
        uint32_t s = bps == 2 ? (uint32_t)p[0] << 8 | p[1] : p[0];
        packed |= (s * 255u / maxval) << (ch * 8);
    }
    if (channels == 1) packed *= 0x010101u;
    return packed | 0xFF000000u;
}

int img_pnm_decode(const uint8_t *d, size_t n, Image *out)
{
    const uint8_t *end = d + n, *p = d + 2;
    uint32_t channels = d[1] == '6' ? 3 : 1, hdr[3];
    for (int i = 0; i < 3; i++) {
        int64_t v = pnm_uint(&p, end);
        if (v <= 0) return IMG_E_FORMAT;
        hdr[i] = (uint32_t)v;
    }
    p++;                                                          /* a single whitespace byte precedes the raster */
    uint32_t bps = hdr[2] > 255 ? 2 : 1;
    int rc = img_alloc(out, (int)hdr[0], (int)hdr[1]);
    if (rc) return rc;
    uint32_t *dst = (uint32_t *)out->px, step = channels * bps;
    for (uint32_t left = hdr[0] * hdr[1]; left; left--, p += step) {
        if ((size_t)(end - p) < step || p > end) break;           /* truncated: keep what was decoded */
        *dst++ = pnm_pixel(p, channels, bps, hdr[2]);
    }
    return 0;
}

/* ---- QOI ("Quite OK Image") ---- */
typedef struct { uint32_t index[64]; uint32_t px, run; const uint8_t *p, *end; } Qoi;

static void qoi_remember(Qoi *q)
{
    uint32_t v = q->px;
    q->index[((v & 0xFF) * 3 + (v >> 8 & 0xFF) * 5 + (v >> 16 & 0xFF) * 7 + (v >> 24) * 11) & 63] = v;
}

/* one op whose tag byte was just consumed; running out of data inside an op ends the stream with the old pixel */
static void qoi_op(Qoi *q, uint32_t tag)
{
    uint32_t px = q->px;
    if (tag == 0xFE || tag == 0xFF) {
        size_t need = tag == 0xFE ? 3 : 4;
        if ((size_t)(q->end - q->p) < need) { q->p = q->end; return; }
        px = tag == 0xFE ? (px & 0xFF000000u) | load_le16(q->p) | (uint32_t)q->p[2] << 16 : load_le32(q->p);
        q->p += need;
    } else {
        uint32_t kind = tag >> 6, v = tag & 0x3F;
        if (kind == 0) {
            px = q->index[v];
        } else if (kind == 3) {
            q->run = v;
        } else {
            int dr, dg, db;
            if (kind == 1) {
                dr = (int)(v >> 4 & 3) - 2; dg = (int)(v >> 2 & 3) - 2; db = (int)(v & 3) - 2;
            } else {
                if (q->p >= q->end) { q->p = q->end; return; }
                uint32_t b2 = *q->p++;
                dg = (int)v - 32; dr = dg + (int)(b2 >> 4) - 8; db = dg + (int)(b2 & 15) - 8;
            }
            uint32_t r = (px + (uint32_t)dr) & 0xFF, g = ((px >> 8) + (uint32_t)dg) & 0xFF, b = ((px >> 16) + (uint32_t)db) & 0xFF;
            px = (px & 0xFF000000u) | b << 16 | g << 8 | r;
        }
    }
    q->px = px;
    qoi_remember(q);
}

int img_qoi_decode(const uint8_t *d, size_t n, Image *out)
{
    if (n < 22) return IMG_E_FORMAT;
    int rc = img_alloc(out, (int)__builtin_bswap32(load_le32(d + 4)), (int)__builtin_bswap32(load_le32(d + 8)));
    if (rc) return rc;
    Qoi q = {.px = 0xFF000000u, .p = d + 14, .end = d + n};
    uint32_t *dst = (uint32_t *)out->px;
    for (uint32_t left = (uint32_t)out->w * (uint32_t)out->h; left; left--) {
        if (q.run) q.run--;
        else if (q.p >= q.end) break;
        else qoi_op(&q, *q.p++);
        *dst++ = q.px;
    }
    return 0;
}
