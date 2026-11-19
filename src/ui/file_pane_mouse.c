/* src/ui/file_pane_mouse.c - FilePane mouse interaction: wheel, hover, tab strip,
 * column-header sort, scrollbar drag, right-click mark, left single/double click
 * (freestanding C23; replaces src/ui/file_pane_mouse.s,
 * kept as tests/harness/file_pane_mouse_reference.s). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"

static void fpm_hover(FilePane *fp, int mx, int my)
{
    int hov_hdr = -1;
    const HitZone *hz = (const HitZone *)fp->hdr_zones;
    int hcnt = (int32_t)fp->hdr_zone_count;
    for (int i = 0; i < hcnt; i++) {
        if (my == (int16_t)hz[i].y && mx >= (int16_t)hz[i].x1 && mx < (int16_t)hz[i].x2) {
            hov_hdr = (int16_t)hz[i].id;
            break;
        }
    }
    int hov_row = -1;
    int top = fp->base.y + 3;
    if (my >= top && my < top + get_list_h(fp)) hov_row = my - top;

    if (hov_hdr != (int32_t)fp->hovered_col_hdr || hov_row != (int32_t)fp->hovered_row) {
        fp->hovered_col_hdr = (uint32_t)hov_hdr;
        fp->hovered_row = (uint32_t)hov_row;
        ((App *)(uintptr_t)fp->app)->need_redraw = 1;
    }
}

static int fpm_press_tabs(FilePane *fp, const Event *ev, int mx, int my)
{
    if (my != fp->base.y || (int32_t)fp->tab_count <= 1) return 0;
    const HitZone *tz = (const HitZone *)fp->tab_zones;
    int tcnt = (int32_t)fp->tab_zone_count;
    App *app = (App *)(uintptr_t)fp->app;
    for (int i = 0; i < tcnt; i++) {
        if (mx < (int16_t)tz[i].x1 || mx >= (int16_t)tz[i].x2) continue;
        int id = (int16_t)tz[i].id;
        if (ev->mouse_btn == MOUSE_MID) {
            FilePane_tab_close(fp, id);
            App_sync_preview(app);
            return 1;
        }
        if (ev->mouse_btn == MOUSE_LEFT) {
            FilePane_tab_switch(fp, id);
            App_sync_preview(app);
            return 1;
        }
    }
    return 0;
}

static int fpm_press_hdr(FilePane *fp, DirModel *m, int mx, int my)
{
    if (my != fp->base.y + 1) return 0;
    const HitZone *hz = (const HitZone *)fp->hdr_zones;
    int hcnt = (int32_t)fp->hdr_zone_count;
    for (int i = 0; i < hcnt; i++) {
        if (mx < (int16_t)hz[i].x1 || mx >= (int16_t)hz[i].x2) continue;
        int id = (int16_t)hz[i].id;
        if (!m->is_unsorted && id == m->sort_mode) {
            m->sort_desc ^= 1;
        } else {
            m->sort_mode = id;
            m->sort_desc = 0;
        }
        DirModel_sort(m);
        fp->cursor = 0;
        fp->scroll = 0;
        App_sync_preview((App *)(uintptr_t)fp->app);
        break;
    }
    return 1;
}

static void fpm_press_row(FilePane *fp, DirModel *m, const Event *ev, int my)
{
    int top = fp->base.y + 3;
    if (my < top || my >= top + get_list_h(fp)) return;
    uint32_t idx = (uint32_t)(my - top) + fp->scroll;
    if ((uint64_t)idx >= m->count) return;

    App *app = (App *)(uintptr_t)fp->app;
    if (ev->mouse_btn == MOUSE_RIGHT) {
        fp->cursor = idx;
        DirModel_toggle_select(m, (intptr_t)idx);
        App_sync_preview(app);
        return;
    }
    if (ev->mouse_btn != MOUSE_LEFT) return;

    int64_t now = sys_clock_ms();
    if (idx == fp->last_click_idx && now - (int64_t)fp->last_click_ms <= DBLCLICK_MS) {
        fp->last_click_idx = (uint32_t)-1;
        fp->cursor = idx;
        App_open_selected_entry(app, fp);
        return;
    }
    fp->cursor = idx;
    fp->last_click_idx = idx;
    fp->last_click_ms = (uint64_t)now;
    FilePane_ensure_visible(fp);
    App_sync_preview(app);
}

int FilePane_on_mouse(Widget *self, void *event)
{
    FilePane *fp = (FilePane *)self;
    const Event *ev = (const Event *)event;
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    App *app = (App *)(uintptr_t)fp->app;
    int mx = ev->mouse_x, my = ev->mouse_y;

    if (ev->mouse_kind == MACT_RELEASE) {
        fp->dragging_scroll = 0;
        return 0;
    }
    if (ev->mouse_kind == MACT_DRAG) {
        if (!fp->dragging_scroll) return 0;
        scrub_scrollbar(fp, my);
        app->need_redraw = 1;
        return 1;
    }
    if (ev->mouse_kind == MACT_WHEEL) {
        int lh = get_list_h(fp);
        int max_scroll = (int32_t)m->count - lh;
        if (max_scroll < 0) max_scroll = 0;
        int scr = (int32_t)fp->scroll;
        if (ev->mouse_btn == MOUSE_WHEEL_UP) { scr -= 3; if (scr < 0) scr = 0; }
        else { scr += 3; if (scr > max_scroll) scr = max_scroll; }
        fp->scroll = (uint32_t)scr;
        app->need_redraw = 1;
        return 1;
    }
    if (ev->mouse_kind == MACT_MOVE) { fpm_hover(fp, mx, my); return 0; }
    if (ev->mouse_kind != MACT_PRESS) return 0;

    App_set_active_pane(app, fp);
    if (!fpm_press_tabs(fp, ev, mx, my) && !fpm_press_hdr(fp, m, mx, my)) {
        int top = fp->base.y + 3;
        if (mx == fp->base.x + fp->base.w - 1 && my >= top && my < top + get_list_h(fp)) {
            fp->dragging_scroll = 1;
            scrub_scrollbar(fp, my);
        } else {
            fpm_press_row(fp, m, ev, my);
        }
    }
    app->need_redraw = 1;
    return 1;
}
