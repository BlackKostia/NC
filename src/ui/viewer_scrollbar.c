/* src/ui/viewer_scrollbar.c - ViewerDialog scrollbars (image V/H + text/hex V + mouse scrub)
 * (freestanding C23; replaces viewer_scrollbar.s, kept as tests/harness/viewer_scrollbar_reference.s). */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_tui.h"
#include "duop_ui.h"

static void vw_draw_bar(ScreenBuffer *scr, const Theme *th, int x, int y, int track_len,
                        int horiz, int64_t pos, int64_t vis, int64_t total)
{
    if (track_len <= 0 || total <= vis || vis <= 0) return;

    uint64_t tlen = ((uint64_t)(uint32_t)track_len * (uint64_t)vis) / (uint64_t)total;
    if (tlen == 0) tlen = 1;
    if ((int64_t)tlen > track_len) tlen = (uint64_t)track_len;

    int travel = track_len - (int)tlen;
    int tpos = 0;
    if (travel > 0) {
        uint64_t max_pos = (uint64_t)(total - vis);
        uint64_t p = ((uint64_t)pos * (uint64_t)(uint32_t)travel) / max_pos;
        tpos = (int)p;
        if (tpos > travel) tpos = travel;
    }

    for (int i = 0; i < track_len; i++) {
        int in_thumb = (i >= tpos && i < tpos + (int)tlen);
        uint32_t fg = in_thumb ? th->scroll_thumb : th->scroll_track;
        uint32_t glyph = in_thumb ? CH_BLOCK_FULL : CH_SHADE_LIGHT;
        ScreenBuffer_set_pen(scr, fg, th->dialog_bg, ATTR_NONE);
        int cx = horiz ? x + i : x;
        int cy = horiz ? y : y + i;
        ScreenBuffer_set_cell_pen(scr, cx, cy, glyph);
    }
}

void vw_draw_img_scrollbars(ViewerDialog *v, ScreenBuffer *scr, const Theme *th)
{
    if (v->img_state != 1 || v->img_zoom == 0) return;
    const Image *img = (const Image *)v->img;

    int vis_h = (int)((v->img_box_h * 100u) / v->img_zoom);
    if (vis_h == 0) vis_h = 1;
    if (vis_h > img->h) vis_h = img->h;
    vw_draw_bar(scr, th, v->base.base.x + v->base.base.w - 1, v->base.base.y + 1,
                v->base.base.h - 3, 0, (int64_t)v->img_pan_y, (int64_t)vis_h, (int64_t)img->h);

    int vis_w = (int)((v->img_box_w * 100u) / v->img_zoom);
    if (vis_w == 0) vis_w = 1;
    if (vis_w > img->w) vis_w = img->w;
    vw_draw_bar(scr, th, v->base.base.x + 1, v->base.base.y + v->base.base.h - 1,
                v->base.base.w - 2, 1, (int64_t)v->img_pan_x, (int64_t)vis_w, (int64_t)img->w);
}

void vw_draw_text_scrollbar(ViewerDialog *v, ScreenBuffer *scr, const Theme *th, int64_t end_off)
{
    if (v->data_len == 0 || (int32_t)v->vis_rows <= 0) return;
    int64_t total, vis, pos;
    if (v->hex_mode == 0) {
        total = (int64_t)v->data_len;
        vis = end_off - (int64_t)v->top_off;
        if (vis < 1) vis = 1;
        pos = (int64_t)v->top_off;
    } else {
        total = (int64_t)((v->data_len + 15u) >> 4);
        vis = (int64_t)(int32_t)v->vis_rows;
        pos = (int64_t)v->hex_row;
    }
    vw_draw_bar(scr, th, v->base.base.x + v->base.base.w - 1, v->base.base.y + 2,
                (int32_t)v->vis_rows, 0, pos, vis, total);
}

static uint32_t vw_scrub_axis(int rel, int track, int img_dim, uint32_t box_dim, uint32_t zoom)
{
    int vis = (int)((box_dim * 100u) / zoom);
    if (vis == 0) vis = 1;
    if (vis > img_dim) vis = img_dim;
    int max_pan = img_dim - vis;
    if (max_pan <= 0) return 0;

    int thumb_len = (int)(((uint32_t)track * (uint32_t)vis) / (uint32_t)img_dim);
    if (thumb_len == 0) thumb_len = 1;
    if (thumb_len > track) thumb_len = track;
    int travel = track - thumb_len;
    if (travel <= 0) return 0;

    int adj = rel - (thumb_len >> 1);
    if (adj < 0) adj = 0;
    if (adj > travel) adj = travel;
    int pan = (int)(((uint32_t)adj * (uint32_t)max_pan) / (uint32_t)travel);
    if (pan > max_pan) pan = max_pan;
    return (uint32_t)pan;
}

static int vw_apply_scrub(ViewerDialog *v, int horiz, int rel, int track)
{
    const Image *img = (const Image *)v->img;
    if (horiz)
        v->img_pan_x = vw_scrub_axis(rel, track, img->w, v->img_box_w, v->img_zoom);
    else
        v->img_pan_y = vw_scrub_axis(rel, track, img->h, v->img_box_h, v->img_zoom);
    vz_invalidate(v);
    return 1;
}

int vw_img_scrollbar_mouse(ViewerDialog *v, Event *e)
{
    if (v->img_zoom == 0) return 0;
    if (e->mouse_kind == MACT_RELEASE) {
        v->img_sb_drag = 0;
        return 0;
    }
    if (e->mouse_btn != MOUSE_LEFT) return 0;

    int mx = e->mouse_x, my = e->mouse_y;
    int vx = v->base.base.x + v->base.base.w - 1;
    int vy = v->base.base.y + 1, vh = v->base.base.h - 3;
    int hx = v->base.base.x + 1, hw = v->base.base.w - 2;
    int hy = v->base.base.y + v->base.base.h - 1;

    if (e->mouse_kind == MACT_PRESS) {
        v->img_sb_drag = 0;
        if (mx == vx && my >= vy && my < vy + vh) {
            v->img_sb_drag = 1;
            return vw_apply_scrub(v, 0, my - vy, vh);
        }
        if (my == hy && mx >= hx && mx < hx + hw) {
            v->img_sb_drag = 2;
            return vw_apply_scrub(v, 1, mx - hx, hw);
        }
        return 0;
    }
    if (e->mouse_kind != MACT_DRAG) return 0;
    if (v->img_sb_drag == 1) {
        int rel = my - vy;
        if (rel < 0) rel = 0;
        if (rel >= vh) rel = vh - 1;
        return vw_apply_scrub(v, 0, rel, vh);
    }
    if (v->img_sb_drag == 2) {
        int rel = mx - hx;
        if (rel < 0) rel = 0;
        if (rel >= hw) rel = hw - 1;
        return vw_apply_scrub(v, 1, rel, hw);
    }
    return 0;
}
