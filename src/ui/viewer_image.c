/* src/ui/viewer_image.c - ViewerDialog picture mode: lazy image decode, mode switching
 * (Image / Hex / Text via i/h/t), image resource cleanup and picture-mode frame rendering
 * (freestanding C23; replaces src/ui/viewer_image.s, kept as tests/harness/viewer_image_reference.s). */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void viewer_img_enter(ViewerDialog *v)
{
    v->img_mode = 1;
    if (v->img_state == 0) {
        int fmt = img_detect((const uint8_t *)(uintptr_t)v->data, (size_t)v->data_len, (const char *)v->path);
        int st = IMG_E_FORMAT;
        if (fmt != 0) {
            Image im;
            mem_copy(&im, v->img, sizeof im);
            int rc = img_decode((const uint8_t *)(uintptr_t)v->data, (size_t)v->data_len, fmt, &im);
            mem_copy(v->img, &im, sizeof im);
            if (rc != 0) st = rc;
            else if (im.w <= 0 || im.h <= 0 || !im.px) st = IMG_E_CORRUPT;
            else st = 1;
        }
        v->img_state = (uint32_t)st;
    }
    App *app = (App *)(uintptr_t)v->base.app;
    if (app) app->need_redraw = 1;
}

void ViewerDialog_set_mode(ViewerDialog *v, int mode)
{
    if (mode == PV_MODE_IMAGE) {
        viewer_img_enter(v);
        return;
    }
    if (mode == PV_MODE_HEX && v->hex_mode == 0)
        ViewerDialog_on_btn0(v);
}

void viewer_img_free(ViewerDialog *v)
{
    Image im;
    mem_copy(&im, v->img, sizeof im);
    img_free(&im);
    mem_copy(v->img, &im, sizeof im);
    mem_free((void *)(uintptr_t)v->thumb);
    v->thumb = 0;
    mem_free((void *)(uintptr_t)v->enc);
    v->enc = 0;
}

int viewer_mode_key(ViewerDialog *v, Event *e)
{
    uint32_t k = e->lat | 0x20u;
    if (k == 'i') {
        if (v->img_mode == 0) {
            viewer_img_enter(v);
            return 1;
        }
        k = 't';
    }
    if (k == 't') {
        v->img_mode = 0;
        if (v->hex_mode != 0) ViewerDialog_on_btn0(v);
        ((App *)(uintptr_t)v->base.app)->need_redraw = 1;
        return 1;
    }
    if (k == 'h') {
        if (v->img_mode == 0) return 0;
        v->img_mode = 0;
        ViewerDialog_set_mode(v, PV_MODE_HEX);
        return 1;
    }
    return 0;
}

static void vim_line(const ViewerDialog *v, ScreenBuffer *scr, const Theme *th,
                     const char *text, int row, uint32_t fg)
{
    ScreenBuffer_set_pen(scr, fg, th->dialog_bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, v->base.base.x + 2, v->base.base.y + row, text, v->base.base.w - 4);
}

void ViewerDialog_render_image(ViewerDialog *v, ScreenBuffer *scr)
{
    const App *app = (const App *)(uintptr_t)v->base.app;
    const Theme *th = (const Theme *)(uintptr_t)app->theme;
    uintptr_t addr = (uintptr_t)v;
    Dialog_draw_frame((Dialog *)addr, scr, th, nullptr, nullptr);
    if (v->img_state == 1)
        vim_draw_picture(v, scr, th);
    else
        vim_line(v, scr, th, i18n_get()->s[LS_img_unsup], 2, th->warn_fg);
    vim_line(v, scr, th, i18n_get()->s[LS_vw_img_hint], v->base.base.h - 2, th->muted);
    vim_draw_zoom_badge(v, scr, th);
    vw_draw_img_scrollbars(v, scr, th);
}
