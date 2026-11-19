/* src/ui/preview_mode.c - PreviewPane presentation modes (Image / Hex / Text via Alt+V),
 * thumbnail box geometry for the async decoder, and the bottom-border mode bar
 * (freestanding C23; replaces src/ui/preview_mode.s, kept as tests/harness/preview_mode_reference.s). */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_preview.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define IMG_PX_MAX 2048u

static void img_box_pixels_k(int cols, int rows, int proto, int *out_w, int *out_h, int *out_cols)
{
    *out_w = 0;
    *out_h = 0;
    *out_cols = 0;
    if (cols <= 0 || rows <= 0) return;
    if (proto == IMG_PROTO_HALF) { *out_w = cols; *out_h = rows * 2; return; }
    if (proto < IMG_PROTO_SIXEL) { *out_w = cols * 2; *out_h = rows * 2; return; }
    CellPx cp = term_cell_px();
    uint32_t cw = (uint32_t)cp.w, ch = (uint32_t)cp.h, kc = 0;
    if (cw == 0 || ch == 0) {
        if (proto == IMG_PROTO_KITTY) {
            cw = 10; ch = 20;
            kc = cols > 255 ? 255u : (uint32_t)cols;
        } else {
            cw = 6; ch = 12;
        }
    }
    uint32_t w = cw * (uint32_t)cols;
    uint32_t h = ch * (uint32_t)rows;
    if (w > IMG_PX_MAX) w = IMG_PX_MAX;
    if (h > IMG_PX_MAX) h = IMG_PX_MAX;
    *out_w = (int)w;
    *out_h = (int)h;
    *out_cols = (int)kc;
}

ImgFit img_box_pixels(int cols, int rows, int proto)
{
    int w = 0, h = 0, unused = 0;
    img_box_pixels_k(cols, rows, proto, &w, &h, &unused);
    return (ImgFit){(uint32_t)w, (uint32_t)h};
}

ImgFit pv_box_pixels(PreviewPane *self, int proto)
{
    return img_box_pixels(self->base.w - 2, self->base.h - 5, proto);
}

uint32_t PreviewPane_thumb_req(PreviewPane *self, PvThumbReq *out)
{
    const App *app = (const App *)(uintptr_t)self->app;
    const Theme *th = (const Theme *)(uintptr_t)app->theme;
    out->bg = th->surface & 0xFFFFFFu;
    int proto = term_img_proto();
    int bw = 0, bh = 0, kc = 0;
    img_box_pixels_k(self->base.w - 2, self->base.h - 5, proto, &bw, &bh, &kc);
    uint32_t mode = ((uint32_t)kc << 8) | (uint32_t)proto;
    out->proto = (uint8_t)proto;
    out->cols = (uint8_t)kc;
    out->pad[0] = 0;
    out->pad[1] = 0;
    self->req_mode = mode;
    if (bw == 0 || bh == 0) {
        out->w = 0;
        out->h = 0;
        return 0;
    }
    out->w = (uint16_t)bw;
    out->h = (uint16_t)bh;
    return (uint32_t)bw | ((uint32_t)bh << 16);
}

static int pv_effective_mode(const PreviewPane *self)
{
    int vm = (int)self->view_mode;
    if (self->thumb_len >= IMG_THUMB_HDR)
        return vm != PV_MODE_AUTO ? vm : PV_MODE_IMAGE;
    if (vm != PV_MODE_IMAGE && vm != PV_MODE_AUTO) return vm;
    return self->is_binary ? PV_MODE_HEX : PV_MODE_TEXT;
}

void PreviewPane_cycle_mode(PreviewPane *self)
{
    int cur = pv_effective_mode(self);
    int next = PV_MODE_TEXT;
    if (cur == PV_MODE_HEX)
        next = PV_MODE_TEXT;
    else if (cur != PV_MODE_TEXT)
        next = PV_MODE_HEX;
    else
        next = self->thumb_len >= IMG_THUMB_HDR ? PV_MODE_IMAGE : PV_MODE_HEX;
    self->view_mode = (uint32_t)next;
    self->scroll = 0;
    ((App *)(uintptr_t)self->app)->need_redraw = 1;
}

static int pmb_text(const PreviewPane *self, ScreenBuffer *scr, int x, const char *s)
{
    int y = self->base.y + self->base.h - 1;
    int room = self->base.x + self->base.w - x - 1;
    if (room > 0) (void)ScreenBuffer_draw_text(scr, x, y, s, room);
    return x + utf8_display_width(s);
}

static void pv_draw_mode_bar(const PreviewPane *self, ScreenBuffer *scr, const Theme *th, int mode)
{
    int x = self->base.x + 2;
    ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
    x = pmb_text(self, scr, x, " Alt+V ");
    const LangStrings *ls = i18n_get();
    for (int m = PV_MODE_IMAGE; m <= PV_MODE_TEXT; m++) {
        const char *lbl = m == PV_MODE_HEX ? ls->s[LS_vas_hex]
                        : m == PV_MODE_TEXT ? ls->s[LS_vas_text]
                        : ls->s[LS_vas_image];
        if (m == mode) ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_BOLD);
        else ScreenBuffer_set_pen(scr, th->text, th->surface, ATTR_NONE);
        x = pmb_text(self, scr, x, " ");
        x = pmb_text(self, scr, x, lbl);
        x = pmb_text(self, scr, x, " ");
    }
}

int pv_mode_dispatch(PreviewPane *self, ScreenBuffer *scr, const Theme *theme)
{
    int eff = pv_effective_mode(self);
    if (self->thumb_len >= IMG_THUMB_HDR) {
        pv_draw_mode_bar(self, scr, theme, eff);
        if (eff == PV_MODE_IMAGE) {
            (void)img_preview_try_render(self, scr, theme);
            return 0;
        }
    } else if (self->view_mode == PV_MODE_AUTO) {
        if (elf_preview_try_render(self, scr, theme)) return 0;
    }
    return eff == PV_MODE_HEX ? 1 : 2;
}
