/* src/fs/img_core.c - image core: format detection, decode dispatch under a fault guard, RGBA buffer management and the
 * area-averaged scaler used by the preview helper (thumbnails) and the viewer (fit to window). Freestanding C23; replaces img_core.s,
 * kept as tests/harness/img_core_reference.s. */
#include "duop_img.h"
#include "duop_oop.h"
#include "duop_string.h"
#include "duop_sys.h"

int img_detect(const uint8_t *d, size_t n, const char *path)
{
    if (n >= 4) {
        uint32_t m = load_le32(d);
        if (m == 0x474E5089) return IMG_FMT_PNG;                       /* \x89PNG */
        if ((m & 0xFFFFFF) == 0xFFD8FF) return IMG_FMT_JPEG;
        if (m == 0x38464947) return IMG_FMT_GIF;                       /* GIF8 */
        if (m == 0x66696F71) return IMG_FMT_QOI;                       /* qoif */
        if ((m & 0xFFFF) == 0x4D42) return IMG_FMT_BMP;                /* BM */
        if (d[0] == 'P' && (d[1] == '5' || d[1] == '6')) return IMG_FMT_PNM;
        if (m == 0x46464952 && n >= 12 && load_le32(d + 8) == 0x50424557) return IMG_FMT_WEBP;   /* RIFF....WEBP */
    }
    if (n < 18 || !path) return 0;                                     /* TGA has no magic: the 18-byte header plus ".tga" */
    size_t len = str_len(path);
    return len >= 4 && !str_casecmp(path + len - 4, ".tga") ? IMG_FMT_TGA : 0;
}

static int img_dispatch(const uint8_t *d, size_t n, int fmt, Image *out)
{
    switch (fmt) {
    case IMG_FMT_PNG: return img_png_decode(d, n, out);
    case IMG_FMT_JPEG: return img_jpeg_decode(d, n, out);
    case IMG_FMT_GIF: return img_gif_decode(d, n, out);
    case IMG_FMT_BMP: return img_bmp_decode(d, n, out);
    case IMG_FMT_PNM: return img_pnm_decode(d, n, out);
    case IMG_FMT_TGA: return img_tga_decode(d, n, out);
    case IMG_FMT_QOI: return img_qoi_decode(d, n, out);
    default: return IMG_E_UNSUP;
    }
}

/* 0 with a w x h RGBA picture in out, or IMG_E_*. A decoder that faults (SIGSEGV / SIGBUS / SIGFPE: a file truncated under its
 * mapping, a decoder bug) yields IMG_E_CORRUPT; a half-decoded picture is never leaked. */
int img_decode(const uint8_t *d, size_t n, int fmt, Image *out)
{
    out->px = nullptr;
    out->fmt = fmt;
    volatile int rc = IMG_E_CORRUPT;
    TryFrame frame;
    if (os_try_begin(&frame) == 0) {
        rc = img_dispatch(d, n, fmt, out);
        os_try_end(&frame);
        if (rc == 0 && (out->w <= 0 || out->h <= 0 || !out->px)) rc = IMG_E_CORRUPT;
    }
    if (rc != 0) img_free(out);
    return rc;
}

int img_alloc(Image *img, int w, int h)
{
    if (w <= 0 || h <= 0 || w > IMG_MAX_DIM || h > IMG_MAX_DIM) return IMG_E_CORRUPT;
    img->w = w;
    img->h = h;
    uint64_t px = (uint64_t)(uint32_t)w * (uint32_t)h;
    if (px > IMG_MAX_PIXELS) return IMG_E_UNSUP;
    img->px = mem_alloc(px * 4);
    return img->px ? 0 : IMG_E_NOMEM;
}

void img_free(Image *img)
{
    mem_free(img->px);
    img->px = nullptr;
}

static int img_at_least_1(uint32_t v) { return (int32_t)v > 0 ? (int32_t)v : 1; }

/* the largest size with the source aspect ratio that fits the box (scales up and down), at least 1 x 1; eax = ow, edx = oh */
ImgFit img_fit(int iw, int ih, int bw, int bh)
{
    uint64_t w = (uint32_t)img_at_least_1((uint32_t)iw), h = (uint32_t)img_at_least_1((uint32_t)ih);
    uint64_t bx = (uint32_t)img_at_least_1((uint32_t)bw), by = (uint32_t)img_at_least_1((uint32_t)bh);
    uint64_t oh = h * bx / w;                                          /* width-bound */
    uint32_t ow32, oh32;
    if (oh <= by) { ow32 = (uint32_t)bx; oh32 = (uint32_t)oh; }
    else { ow32 = (uint32_t)(w * by / h); oh32 = (uint32_t)by; }      /* height-bound */
    return (ImgFit){(uint32_t)img_at_least_1(ow32), (uint32_t)img_at_least_1(oh32)};
}

/* source span [s0, s1) of destination index i: s0 = i * src / dst, s1 = max(s0 + 1, (i + 1) * src / dst) */
static void isc_span(uint32_t i, uint32_t src, uint32_t dst, int32_t *s0, int32_t *s1)
{
    int32_t a = (int32_t)(uint32_t)((uint64_t)i * src / dst);
    int32_t b = (int32_t)(uint32_t)((uint64_t)(uint32_t)(i + 1) * src / dst);
    *s0 = a;
    *s1 = b > a ? b : a + 1;
}

/* the mean of the source block, packed A<<24 | B<<16 | G<<8 | R (bytes R, G, B, A in memory); opaque black for an empty block */
static uint32_t isc_average(const uint8_t *px, int32_t iw, int32_t x0, int32_t x1, int32_t y0, int32_t y1)
{
    if (x0 >= x1 || y0 >= y1) return 0xFF000000;
    uint64_t r = 0, g = 0, b = 0, a = 0;
    uint32_t n = (uint32_t)(x1 - x0);
    for (int32_t y = y0; y < y1; y++) {
        const uint8_t *p = px + (uint64_t)((uint32_t)y * (uint32_t)iw + (uint32_t)x0) * 4;   /* 32-bit index, as before */
        for (uint32_t k = 0; k < n; k++, p += 4) {
            r += p[0];
            g += p[1];
            b += p[2];
            a += p[3];
        }
    }
    uint32_t taps = n * (uint32_t)(y1 - y0);
    return (uint32_t)(a / taps) << 24 | (uint32_t)(b / taps) << 16 | (uint32_t)(g / taps) << 8 | (uint32_t)(r / taps);
}

/* area-averaged downscale / nearest upscale of rect {x, y, w, h} of src into an ow x oh RGBA buffer (dst may be unaligned) */
void img_scale_rect(const Image *src, uint8_t *dst, int ow, int oh, const int *rect)
{
    for (int32_t dy = 0; dy < oh; dy++) {
        int32_t y0, y1;
        isc_span((uint32_t)dy, (uint32_t)rect[3], (uint32_t)oh, &y0, &y1);
        y0 = (int32_t)((uint32_t)y0 + (uint32_t)rect[1]);             /* 32-bit wrap-around, as before */
        y1 = (int32_t)((uint32_t)y1 + (uint32_t)rect[1]);
        for (int32_t dx = 0; dx < ow; dx++) {
            int32_t x0, x1;
            isc_span((uint32_t)dx, (uint32_t)rect[2], (uint32_t)ow, &x0, &x1);
            x0 = (int32_t)((uint32_t)x0 + (uint32_t)rect[0]);
            x1 = (int32_t)((uint32_t)x1 + (uint32_t)rect[0]);
            uint32_t v = isc_average(src->px, src->w, x0, x1, y0, y1);
            __builtin_memcpy(dst, &v, 4);
            dst += 4;
        }
    }
}

void img_scale(const Image *src, uint8_t *dst_rgba, int ow, int oh)
{
    const int rect[4] = {0, 0, src->w, src->h};
    img_scale_rect(src, dst_rgba, ow, oh, rect);
}
