/* src/ui/viewer_zoom.c - ViewerDialog image zoom & pan input (+/-, 1, 0/f, b, o, arrows, mouse wheel)
 * (freestanding C23; replaces viewer_zoom.s, kept as tests/harness/viewer_zoom_reference.s). */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"

static const int zoom_steps[13] = {
    25, 33, 50, 67, 75, 100, 125, 150, 200, 300, 400, 600, 800,
};

void vz_invalidate(ViewerDialog *v)
{
    v->img_cache_key = (uint64_t)-1;
    v->enc_key = 0;
    App *app = (App *)(uintptr_t)v->base.app;
    app->need_redraw = 1;
}

static int vz_cur_pct(const ViewerDialog *v)
{
    if (v->img_zoom != 0) return (int)v->img_zoom;
    const Image *im = (const Image *)v->img;
    if (v->img_box_w == 0 || v->img_box_h == 0 || im->w <= 0) return 100;
    ImgFit f = img_fit(im->w, im->h, (int)v->img_box_w, (int)v->img_box_h);
    int pct = (int)(((uint32_t)f.w * 100u) / (uint32_t)im->w);
    return pct < 10 ? 10 : pct;
}

static void vz_set_zoom(ViewerDialog *v, int pct)
{
    uint32_t prev = v->img_zoom;
    v->img_zoom = (uint32_t)pct;
    if (pct == 0) {
        v->img_pan_x = 0;
        v->img_pan_y = 0;
    } else if (prev == 0) {
        const Image *im = (const Image *)v->img;
        int vw = (int)((v->img_box_w * 100u) / (uint32_t)pct);
        int px = (im->w - vw) >> 1;
        v->img_pan_x = (uint32_t)(px < 0 ? 0 : px);
        int vh = (int)((v->img_box_h * 100u) / (uint32_t)pct);
        int py = (im->h - vh) >> 1;
        v->img_pan_y = (uint32_t)(py < 0 ? 0 : py);
    }
    vz_invalidate(v);
}

static void vz_step_zoom(ViewerDialog *v, int dir)
{
    int cur = vz_cur_pct(v);
    int next;
    if (dir >= 0) {
        next = 800;
        for (int i = 0; i < 13; i++) {
            if (zoom_steps[i] > cur) { next = zoom_steps[i]; break; }
        }
    } else {
        next = 0;
        for (int i = 12; i >= 0; i--) {
            if (zoom_steps[i] < cur) { next = zoom_steps[i]; break; }
        }
    }
    vz_set_zoom(v, next);
}

static uint32_t vz_pan_axis(uint32_t cur, int delta, int img_dim, uint32_t box_dim, uint32_t zoom)
{
    int vis = (int)((box_dim * 100u) / zoom);
    if (vis == 0) vis = 1;
    int step = vis >> 4;
    if (step == 0) step = 1;
    int np = (int)cur + delta * step;
    int max_p = img_dim - vis;
    if (max_p < 0) max_p = 0;
    if (np < 0) np = 0;
    if (np > max_p) np = max_p;
    return (uint32_t)np;
}

static void vz_pan(ViewerDialog *v, int dx, int dy)
{
    if (v->img_zoom == 0) return;
    const Image *im = (const Image *)v->img;
    v->img_pan_x = vz_pan_axis(v->img_pan_x, dx, im->w, v->img_box_w, v->img_zoom);
    v->img_pan_y = vz_pan_axis(v->img_pan_y, dy, im->h, v->img_box_h, v->img_zoom);
}

int vim_zoom_key(ViewerDialog *v, Event *e)
{
    if (v->img_mode == 0 || v->img_state != 1) return 0;
    const Image *im = (const Image *)v->img;
    switch (e->lat) {
    case '+': case '=': vz_step_zoom(v, 1); return 1;
    case '-': case '_': vz_step_zoom(v, -1); return 1;
    case '1': vz_set_zoom(v, 100); return 1;
    case '0': case 'f': vz_set_zoom(v, 0); return 1;
    case 'b': case 'B': v->img_braille ^= 1; vz_invalidate(v); return 1;
    case 'o': case 'O': {
        App *app = (App *)(uintptr_t)v->base.app;
        (void)sys_open_external((const char *)v->path, (char **)(uintptr_t)app->envp);
        return 1;
    }
    case KEY_LEFT:  vz_pan(v, -1, 0); vz_invalidate(v); return 1;
    case KEY_RIGHT: vz_pan(v, 1, 0);  vz_invalidate(v); return 1;
    case KEY_UP:    vz_pan(v, 0, -1); vz_invalidate(v); return 1;
    case KEY_DOWN:  vz_pan(v, 0, 1);  vz_invalidate(v); return 1;
    case KEY_PGUP:  vz_pan(v, 0, -4); vz_invalidate(v); return 1;
    case KEY_PGDN:  vz_pan(v, 0, 4);  vz_invalidate(v); return 1;
    case KEY_HOME:  v->img_pan_x = 0; v->img_pan_y = 0; vz_invalidate(v); return 1;
    case KEY_END:   v->img_pan_x = (uint32_t)im->w; v->img_pan_y = (uint32_t)im->h; vz_invalidate(v); return 1;
    default:        return 0;
    }
}

int vim_zoom_mouse(ViewerDialog *v, Event *e)
{
    if (v->img_mode == 0 || v->img_state != 1) return 0;
    if (e->mouse_kind != MACT_WHEEL) return vw_img_scrollbar_mouse(v, e);

    int mods = e->mods;
    if (v->img_zoom == 0 || (mods & MOD_CTRL)) {
        vz_step_zoom(v, e->mouse_btn == MOUSE_WHEEL_UP ? 1 : -1);
        return 1;
    }
    int dir = e->mouse_btn == MOUSE_WHEEL_UP ? -1 : 1;
    const Image *im = (const Image *)v->img;
    int horiz = (mods & MOD_SHIFT) != 0 || (int)((v->img_box_h * 100u) / v->img_zoom) >= im->h;
    vz_pan(v, horiz ? dir : 0, horiz ? 0 : dir);
    vz_invalidate(v);
    return 1;
}
