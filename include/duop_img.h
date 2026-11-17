/* include/duop_img.h - C view of the image layer (src/fs/img_*.c): the decoded picture and the decoder entry points.
 * Layouts mirror include/types.inc and config.inc; tests/test_abi_layouts.py compares every offset and value. */
#pragma once
#include "duop_abi.h"

#define IMG_FMT_NONE 0
#define IMG_FMT_PNG 1
#define IMG_FMT_JPEG 2
#define IMG_FMT_GIF 3
#define IMG_FMT_BMP 4
#define IMG_FMT_PNM 5
#define IMG_FMT_TGA 6
#define IMG_FMT_QOI 7
#define IMG_FMT_WEBP 8             /* detected, not decoded */
#define IMG_MAX_DIM 16384
#define IMG_MAX_PIXELS 40000000
#define IMG_E_FORMAT (-1)          /* not an image / bad header */
#define IMG_E_UNSUP (-2)           /* valid but unsupported variant (progressive JPEG, WebP, ...) */
#define IMG_E_CORRUPT (-3)
#define IMG_E_NOMEM (-4)

/* Decoded picture: RGBA8 rows, bytes R,G,B,A per pixel (a uint32_t is A<<24 | B<<16 | G<<8 | R). 24 bytes. */
typedef struct Image {
    uint8_t *px;                   /* w * h * 4 bytes (mem_alloc) */
    int32_t w, h, fmt, pad;
} Image;
_Static_assert(sizeof(Image) == 24, "Image is shared with assembly");

/* ---- image core (img_core.c) ---- */
int img_detect(const uint8_t *d, size_t n, const char *path);            /* IMG_FMT_*, 0 = not an image (TGA: 18 bytes + ".tga") */
int img_decode(const uint8_t *d, size_t n, int fmt, Image *out);         /* 0, or IMG_E_* (a faulting decoder: IMG_E_CORRUPT), out freed */
typedef struct ImgFit { uint64_t w, h; } ImgFit;                         /* asm callers read eax = ow, edx = oh */
ImgFit img_fit(int iw, int ih, int bw, int bh);                          /* aspect-preserving fit into the box, >= 1 x 1 */
void img_scale(const Image *src, uint8_t *dst_rgba, int ow, int oh);
void img_scale_rect(const Image *src, uint8_t *dst_rgba, int ow, int oh, const int *rect /* x, y, w, h */);
int img_alloc(Image *img, int w, int h);   /* 0, IMG_E_CORRUPT (bad size), IMG_E_UNSUP (too many pixels) or IMG_E_NOMEM */
void img_free(Image *img);

/* Decoders: 0 or IMG_E_*; a truncated raster keeps the rows decoded so far. d must hold n readable bytes. */
int img_bmp_decode(const uint8_t *d, size_t n, Image *out);
int img_tga_decode(const uint8_t *d, size_t n, Image *out);
int img_pnm_decode(const uint8_t *d, size_t n, Image *out);
int img_qoi_decode(const uint8_t *d, size_t n, Image *out);
int img_gif_decode(const uint8_t *d, size_t n, Image *out);   /* first frame; a broken LZW stream keeps the pixels so far */
int img_png_decode(const uint8_t *d, size_t n, Image *out);   /* plain and Adam7, all color types / depths, tRNS */
int img_jpeg_decode(const uint8_t *d, size_t n, Image *out);   /* baseline Huffman, 1 or 3 components, any power-of-two subsampling */

/* Terminal picture encoders (preview helper and viewer): bytes written, 0 when `cap` is too small or on OOM */
size_t img_b64_encode(const uint8_t *src, size_t len, char *dst);                 /* with '=' padding */
size_t img_kitty_encode(const uint8_t *rgba, int w, int h, int cols /* 0 = native size, < 0 = transmit only */, uint8_t *out, size_t cap);
size_t img_kitty_place(uint8_t *out, const int *rect /* x, y, w, h in pixels */, int cols, int rows);
int img_quantize(const uint8_t *rgba, size_t n, uint32_t bg /* 0xRRGGBB */, uint8_t *idx, uint32_t *pal /* 256 x 0x00RRGGBB */);   /* palette size, 0 on OOM */
size_t img_sixel_encode(const uint8_t *rgba, int w, int h, uint32_t bg /* 0xRRGGBB */, uint8_t *out, size_t cap);
