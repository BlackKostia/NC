/* src/ui/img_preview.c - Alpha blending and TrueColor half-block (▀) RGBA image renderer
 * (freestanding C23; replaces img_preview.s, kept as tests/harness/img_preview_reference.s). */
#include "duop_img.h"
#include "duop_tui.h"
#include "duop_ui.h"

uint32_t img_blend(uint32_t rgba, uint32_t bg)
{
    uint32_t a = rgba >> 24;
    uint32_t inv_a = 255u - a;
    uint32_t out = 0;

    for (int c = 0; c < 3; c++) {
        uint32_t src = (rgba >> (c * 8)) & 0xFFu;
        uint32_t bch = (bg >> (16 - c * 8)) & 0xFFu;
        uint32_t mix = src * a + bch * inv_a;
        uint32_t ch = (mix * 257u + 257u) >> 16;
        out = (out << 8) | ch;
    }
    if (out == 0) out = 0x010101u;
    return out | 0x01000000u;
}

static uint32_t idr_sample(const ImgView *v, uint32_t dw, uint32_t dh, uint32_t cx, uint32_t py)
{
    uint32_t sy = (py * (uint32_t)v->ih) / dh;
    uint32_t sx = (cx * (uint32_t)v->iw) / dw;
    uint32_t rgba = load_le32(v->rgba + ((size_t)sy * (size_t)v->iw + (size_t)sx) * 4);
    return img_blend(rgba, v->bg);
}

void img_draw_rgba(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
{
    ImgFit f = img_fit(v->iw, v->ih, bw, bh * 2);
    uint32_t dw = (uint32_t)f.w;
    uint32_t dh = (uint32_t)f.h;
    if (dw == 0 || dh == 0) return;

    int rows = (int)((dh + 1u) >> 1);
    int x0 = bx + ((bw - (int)dw) >> 1);
    int y0 = by + ((bh - rows) >> 1);

    for (int cy = 0; cy < rows; cy++) {
        uint32_t py = (uint32_t)cy * 2u;
        for (int cx = 0; cx < (int)dw; cx++) {
            uint32_t top = idr_sample(v, dw, dh, (uint32_t)cx, py);
            uint32_t bot = py + 1 < dh ? idr_sample(v, dw, dh, (uint32_t)cx, py + 1) : v->bg;
            ScreenBuffer_set_cell(scr, x0 + cx, y0 + cy, 0x2580u, top, bot);
        }
    }
}
