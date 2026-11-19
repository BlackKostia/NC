/* src/ui/img_quad.c - Quadrant-block (2x2) TrueColor image renderer with least-squares 2-color split
 * (freestanding C23; replaces img_quad.s, kept as tests/harness/img_quad_reference.s). */
#include "duop_img.h"
#include "duop_tui.h"
#include "duop_ui.h"

static const uint32_t quad_glyph[8] = {
    0x2580u, 0x2598u, 0x259Du, 0x2580u, 0x2596u, 0x258Cu, 0x259Eu, 0x259Bu,
};

static uint32_t qd_color(uint32_t c)
{
    return (c ? c : 0x010101u) | 0x01000000u;
}

static uint32_t qd_sample(const ImgView *v, uint32_t dw, uint32_t dh, uint32_t px, uint32_t py)
{
    if (px >= dw || py >= dh) return v->bg & 0xFFFFFFu;
    uint32_t sy = (py * (uint32_t)v->ih) / dh;
    uint32_t sx = (px * (uint32_t)v->iw) / dw;
    uint32_t rgba = load_le32(v->rgba + ((size_t)sy * (size_t)v->iw + (size_t)sx) * 4);
    return img_blend(rgba, v->bg) & 0xFFFFFFu;
}

static uint32_t qd_dist(uint32_t a, uint32_t b)
{
    int dr = (int)((a >> 16) & 0xFFu) - (int)((b >> 16) & 0xFFu);
    int dg = (int)((a >> 8) & 0xFFu) - (int)((b >> 8) & 0xFFu);
    int db = (int)(a & 0xFFu) - (int)(b & 0xFFu);
    return (uint32_t)(dr * dr + dg * dg + db * db);
}

static uint32_t qd_group_mean(const uint32_t px[4], uint32_t mask, uint32_t inside)
{
    uint32_t rs = 0, gs = 0, bs = 0, cnt = 0;
    for (uint32_t k = 0; k < 4; k++) {
        if (mask != 0 && (((mask >> k) & 1u) != inside)) continue;
        rs += (px[k] >> 16) & 0xFFu;
        gs += (px[k] >> 8) & 0xFFu;
        bs += px[k] & 0xFFu;
        cnt++;
    }
    if (cnt == 0) return 0;
    return ((rs / cnt) << 16) | ((gs / cnt) << 8) | (bs / cnt);
}

static void qd_cell(ScreenBuffer *scr, const ImgView *v, uint32_t dw, uint32_t dh,
                    int x0, int y0, int cx, int cy)
{
    uint32_t px[4];
    for (uint32_t k = 0; k < 4; k++)
        px[k] = qd_sample(v, dw, dh, (uint32_t)cx * 2u + (k & 1u), (uint32_t)cy * 2u + (k >> 1));

    uint32_t best_mask = 0, best_fg = 0, best_bg = 0;
    uint32_t best_err = 0xFFFFFFFFu;
    for (uint32_t mask = 0; mask <= 7; mask++) {
        uint32_t fg = qd_group_mean(px, mask, 1);
        uint32_t bg = mask == 0 ? fg : qd_group_mean(px, mask, 0);
        uint32_t err = 0;
        for (uint32_t k = 0; k < 4; k++) {
            uint32_t ref = (mask == 0 || ((mask >> k) & 1u)) ? fg : bg;
            err += qd_dist(ref, px[k]);
        }
        if (err < best_err) {
            best_err = err;
            best_mask = mask;
            best_fg = fg;
            best_bg = bg;
        }
    }
    if (best_mask == 0) best_bg = best_fg;
    ScreenBuffer_set_cell(scr, x0 + cx, y0 + cy, quad_glyph[best_mask],
                          qd_color(best_fg), qd_color(best_bg));
}

void img_draw_quad(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
{
    ImgFit f = img_fit(v->iw, v->ih, bw * 2, bh * 2);
    uint32_t dw = (uint32_t)f.w;
    uint32_t dh = (uint32_t)f.h;
    if (dw == 0 || dh == 0) return;

    int cols = (int)((dw + 1u) >> 1);
    int rows = (int)((dh + 1u) >> 1);
    int x0 = bx + ((bw - cols) >> 1);
    int y0 = by + ((bh - rows) >> 1);

    for (int cy = 0; cy < rows; cy++)
        for (int cx = 0; cx < cols; cx++)
            qd_cell(scr, v, dw, dh, x0, y0, cx, cy);
}
