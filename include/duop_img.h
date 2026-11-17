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

int img_alloc(Image *img, int w, int h);   /* 0, IMG_E_CORRUPT (bad size), IMG_E_UNSUP (too many pixels) or IMG_E_NOMEM */
void img_free(Image *img);

/* Decoders: 0 or IMG_E_*; a truncated raster keeps the rows decoded so far. d must hold n readable bytes. */
int img_bmp_decode(const uint8_t *d, size_t n, Image *out);
int img_tga_decode(const uint8_t *d, size_t n, Image *out);
int img_pnm_decode(const uint8_t *d, size_t n, Image *out);
int img_qoi_decode(const uint8_t *d, size_t n, Image *out);
