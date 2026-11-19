/* src/ui/img_braille.c - 2x4 Braille (U+2800..U+28FF) adaptive-threshold TrueColor image renderer
 * (freestanding C23; replaces img_braille.s, kept as tests/harness/img_braille_reference.s). */
#include "duop_img.h"
#include "duop_tui.h"
#include "duop_ui.h"

static const uint8_t br_dx[8] = {0, 0, 0, 1, 1, 1, 0, 1};
static const uint8_t br_dy[8] = {0, 1, 2, 0, 1, 2, 3, 3};

static uint32_t br_sample(const ImgView *v, uint32_t dw, uint32_t dh, uint32_t px, uint32_t py)
{
    if (px >= dw || py >= dh) return v->bg & 0xFFFFFFu;
    uint32_t sy = (py * (uint32_t)v->ih) / dh;
    uint32_t sx = (px * (uint32_t)v->iw) / dw;
    uint32_t rgba = load_le32(v->rgba + ((size_t)sy * (size_t)v->iw + (size_t)sx) * 4);
    return img_blend(rgba, v->bg) & 0xFFFFFFu;
}

static uint32_t br_pick_mask(const uint8_t lum[8])
{
    int lo = 255, hi = 0;
    for (int k = 0; k < 8; k++) {
        if (lum[k] < lo) lo = lum[k];
        if (lum[k] > hi) hi = lum[k];
    }
    if (hi - lo < 16) return 0;
    int mid = (lo + hi) >> 1;
    uint32_t mask = 0;
    int cnt = 0;
    for (int k = 0; k < 8; k++) {
        if (lum[k] > mid) {
            mask |= 1u << k;
            cnt++;
        }
    }
    if (cnt > 4) mask = (~mask) & 0xFFu;
    return mask;
}

static uint32_t br_mean_rgb(const uint32_t px[8], uint32_t mask, uint32_t inside)
{
    uint32_t rs = 0, gs = 0, bs = 0, cnt = 0;
    for (uint32_t k = 0; k < 8; k++) {
        if (mask != 0 && (((mask >> k) & 1u) != inside)) continue;
        rs += (px[k] >> 16) & 0xFFu;
        gs += (px[k] >> 8) & 0xFFu;
        bs += px[k] & 0xFFu;
        cnt++;
    }
    if (cnt == 0) return 0;
    return ((rs / cnt) << 16) | ((gs / cnt) << 8) | (bs / cnt);
}

static void br_cell(ScreenBuffer *scr, const ImgView *v, uint32_t dw, uint32_t dh,
                    int x0, int y0, int cx, int cy)
{
    uint32_t px[8];
    uint8_t lum[8];
    for (int k = 0; k < 8; k++) {
        uint32_t c = br_sample(v, dw, dh, (uint32_t)cx * 2u + br_dx[k], (uint32_t)cy * 4u + br_dy[k]);
        px[k] = c;
        uint32_t r = (c >> 16) & 0xFFu;
        uint32_t g = (c >> 8) & 0xFFu;
        uint32_t b = c & 0xFFu;
        lum[k] = (uint8_t)((r * 77u + g * 150u + b * 29u) >> 8);
    }
    uint32_t mask = br_pick_mask(lum);
    uint32_t fg = br_mean_rgb(px, mask, 1);
    uint32_t bg = br_mean_rgb(px, mask, 0);
    if (mask == 0) fg = bg;

    uint32_t fg_c = fg ? (fg | 0x01000000u) : 0x01010101u;
    uint32_t bg_c = bg ? (bg | 0x01000000u) : 0x01010101u;
    ScreenBuffer_set_cell(scr, x0 + cx, y0 + cy, 0x2800u + mask, fg_c, bg_c);
}

void img_draw_braille(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
{
    ImgFit f = img_fit(v->iw, v->ih, bw * 2, bh * 4);
    uint32_t dw = (uint32_t)f.w;
    uint32_t dh = (uint32_t)f.h;
    if (dw == 0 || dh == 0) return;

    int cols = (int)((dw + 1u) >> 1);
    int rows = (int)((dh + 3u) >> 2);
    int x0 = bx + ((bw - cols) >> 1);
    int y0 = by + ((bh - rows) >> 1);

    for (int cy = 0; cy < rows; cy++)
        for (int cx = 0; cx < cols; cx++)
            br_cell(scr, v, dw, dh, x0, y0, cx, cy);
}
