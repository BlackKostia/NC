/* src/ui/header_bar.c - Top header bar widget: brand badge, mode pill + git badge,
 * progressive right-aligned clickable action pills with hover highlight
 * (freestanding C23; replaces src/ui/header_bar.s and src/ui/header_bar_render.s,
 * kept as tests/harness/header_bar*_reference.s). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

WIDGET_VTBL(HeaderBar_vtbl, "HeaderBar", Widget_vtbl, sizeof(HeaderBar),
            .layout = HeaderBar_layout, .render = HeaderBar_render, .on_mouse = HeaderBar_on_mouse);

HeaderBar *HeaderBar_new(App *app)
{
    HeaderBar *hb = DUOP_NEW(HeaderBar, HeaderBar_vtbl);
    if (!hb) return nullptr;
    Widget_init(&hb->base, app, 100);
    hb->app = (uint64_t)(uintptr_t)app;
    hb->hovered_id = (uint32_t)-1;
    return hb;
}

static int try_add_hdr_pill(HeaderBar *hb, int *right_x, int min_x, int pill_w, int y, int id)
{
    int nx = *right_x - pill_w - 1;
    if (nx < min_x) return 0;
    *right_x = nx;
    if (hb->zone_count < 8) {
        HitZone *z = &((HitZone *)hb->zones)[hb->zone_count++];
        z->x1 = (uint16_t)nx;
        z->x2 = (uint16_t)(nx + pill_w);
        z->y = (uint16_t)y;
        z->id = (uint16_t)id;
    }
    return 1;
}

void HeaderBar_layout(Widget *self, int x, int y, int w, int h)
{
    HeaderBar *hb = (HeaderBar *)self;
    Widget_layout(self, x, y, w, h);
    hb->zone_count = 0;

    const LangStrings *ls = i18n_get();
    int right_x = hb->base.x + w;
    int bw = utf8_display_width(ls->s[LS_hdr_brand]);
    int md = utf8_display_width(ls->s[LS_hdr_mode_dual]);
    int mp = utf8_display_width(ls->s[LS_hdr_mode_prev]);
    int mw = mp > md ? mp : md;
    int min_x = hb->base.x + bw + mw + 2;

    if (!try_add_hdr_pill(hb, &right_x, min_x, utf8_display_width(ls->s[LS_hdr_btn_quit]), y, HDR_BTN_QUIT)) return;
    if (!try_add_hdr_pill(hb, &right_x, min_x, utf8_display_width(ls->s[LS_hdr_btn_help]), y, HDR_BTN_HELP)) return;
    if (!try_add_hdr_pill(hb, &right_x, min_x, utf8_display_width(ls->s[LS_hdr_btn_lang]), y, HDR_BTN_LANG)) return;

    int ho = utf8_display_width(ls->s[LS_hdr_btn_hid_on]);
    int hf = utf8_display_width(ls->s[LS_hdr_btn_hid_off]);
    if (!try_add_hdr_pill(hb, &right_x, min_x, ho > hf ? ho : hf, y, HDR_BTN_HIDDEN)) return;
    if (!try_add_hdr_pill(hb, &right_x, min_x, utf8_display_width(ls->s[LS_hdr_btn_prev]), y, HDR_BTN_PREVIEW)) return;
    (void)try_add_hdr_pill(hb, &right_x, min_x, utf8_display_width(ls->s[LS_hdr_theme_pfx]) + 12, y, HDR_BTN_THEME);
}

static const char *hdr_pill_label(const HeaderBar *hb, const LangStrings *ls, const Theme *th,
                                  int id, char *buf, size_t cap)
{
    switch (id) {
    case HDR_BTN_QUIT: return ls->s[LS_hdr_btn_quit];
    case HDR_BTN_HELP: return ls->s[LS_hdr_btn_help];
    case HDR_BTN_LANG: return ls->s[LS_hdr_btn_lang];
    case HDR_BTN_PREVIEW: return ls->s[LS_hdr_btn_prev];
    case HDR_BTN_HIDDEN: {
        const App *app = (const App *)(uintptr_t)hb->app;
        const FilePane *fp = app ? (const FilePane *)(uintptr_t)app->active_pane : nullptr;
        const DirModel *m = fp ? (const DirModel *)(uintptr_t)fp->model : nullptr;
        return (m && m->show_hidden) ? ls->s[LS_hdr_btn_hid_on] : ls->s[LS_hdr_btn_hid_off];
    }
    case HDR_BTN_THEME:
        (void)str_copy(buf, ls->s[LS_hdr_theme_pfx], cap);
        (void)str_cat(buf, th->name, cap);
        return buf;
    default: return nullptr;
    }
}

void HeaderBar_render(Widget *self, void *screen, void *theme)
{
    HeaderBar *hb = (HeaderBar *)self;
    ScreenBuffer *scr = (ScreenBuffer *)screen;
    const Theme *th = (const Theme *)theme;
    const LangStrings *ls = i18n_get();

    ScreenBuffer_set_pen(scr, th->header_fg, th->header_bg, ATTR_NONE);
    ScreenBuffer_fill_rect(scr, hb->base.x, hb->base.y, hb->base.w, 1, ' ');

    ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, hb->base.x, hb->base.y, ls->s[LS_hdr_brand], hb->base.w);
    hdr_draw_mode_and_git(hb, scr, th, ls);

    const HitZone *zs = (const HitZone *)hb->zones;
    int cnt = (int32_t)hb->zone_count;
    char buf[48];
    for (int i = 0; i < cnt; i++) {
        int id = (int16_t)zs[i].id;
        int x1 = (int16_t)zs[i].x1;
        int w = (int16_t)zs[i].x2 - x1;
        bool hov = id == (int32_t)hb->hovered_id;
        ScreenBuffer_set_pen(scr, hov ? th->accent_fg : th->badge_fg,
                             hov ? th->accent : th->badge_bg,
                             hov ? ATTR_BOLD : ATTR_NONE);
        const char *lbl = hdr_pill_label(hb, ls, th, id, buf, sizeof buf);
        if (lbl) ScreenBuffer_draw_text_pad(scr, x1, hb->base.y, lbl, w);
    }
}

int HeaderBar_on_mouse(Widget *self, void *event)
{
    HeaderBar *hb = (HeaderBar *)self;
    const Event *ev = (const Event *)event;
    int mx = ev->mouse_x, my = ev->mouse_y, hit = -1;

    const HitZone *zs = (const HitZone *)hb->zones;
    int cnt = (int32_t)hb->zone_count;
    for (int i = 0; i < cnt; i++) {
        if (my == (int16_t)zs[i].y && mx >= (int16_t)zs[i].x1 && mx < (int16_t)zs[i].x2) {
            hit = (int16_t)zs[i].id;
            break;
        }
    }

    App *app = (App *)(uintptr_t)hb->app;
    if (ev->mouse_kind == MACT_MOVE) {
        if (hit != (int32_t)hb->hovered_id) {
            hb->hovered_id = (uint32_t)hit;
            app->need_redraw = 1;
        }
        return 0;
    }
    if (ev->mouse_kind == MACT_PRESS) {
        if (ev->mouse_btn != MOUSE_LEFT || hit == -1) return 0;
        switch (hit) {
        case HDR_BTN_THEME:   App_cmd_cycle_theme(app); break;
        case HDR_BTN_PREVIEW: App_cmd_toggle_preview(app); break;
        case HDR_BTN_HIDDEN:  App_cmd_toggle_hidden(app); break;
        case HDR_BTN_LANG:    App_cmd_toggle_lang(app); break;
        case HDR_BTN_HELP:    App_cmd_help(app); break;
        case HDR_BTN_QUIT:    App_cmd_quit(app); break;
        default: break;
        }
        return 1;
    }
    return 0;
}
