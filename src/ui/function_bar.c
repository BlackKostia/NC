/* src/ui/function_bar.c - Bottom interactive F1..F10 action bar with hover highlights
 * and mouse click dispatch (freestanding C23; replaces src/ui/function_bar.s,
 * kept as tests/harness/function_bar_reference.s). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static const char *const f_nums[10] = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "0"};

WIDGET_VTBL(FunctionBar_vtbl, "FunctionBar", Widget_vtbl, sizeof(FunctionBar),
            .layout = FunctionBar_layout, .render = FunctionBar_render, .on_mouse = FunctionBar_on_mouse);

FunctionBar *FunctionBar_new(App *app)
{
    FunctionBar *fb = DUOP_NEW(FunctionBar, FunctionBar_vtbl);
    if (!fb) return nullptr;
    Widget_init(&fb->base, app, 101);
    fb->app = (uint64_t)(uintptr_t)app;
    fb->hovered_id = (uint32_t)-1;
    return fb;
}

void FunctionBar_layout(Widget *self, int x, int y, int w, int h)
{
    FunctionBar *fb = (FunctionBar *)self;
    Widget_layout(self, x, y, w, h);
    fb->zone_count = 10;
    HitZone *zs = (HitZone *)fb->zones;
    uint32_t uw = (uint32_t)w;
    for (uint32_t i = 0; i < 10; i++) {
        uint32_t x1 = (uint32_t)fb->base.x + (i * uw) / 10u;
        uint32_t x2 = (uint32_t)fb->base.x + ((i + 1u) * uw) / 10u;
        zs[i].x1 = (uint16_t)x1;
        zs[i].x2 = (uint16_t)x2;
        zs[i].y = (uint16_t)fb->base.y;
        zs[i].id = (uint16_t)i;
    }
}

void FunctionBar_render(Widget *self, void *screen, void *theme)
{
    FunctionBar *fb = (FunctionBar *)self;
    ScreenBuffer *scr = (ScreenBuffer *)screen;
    const Theme *th = (const Theme *)theme;

    ScreenBuffer_set_pen(scr, th->text, th->header_bg, ATTR_NONE);
    ScreenBuffer_fill_rect(scr, fb->base.x, fb->base.y, fb->base.w, 1, ' ');

    const HitZone *zs = (const HitZone *)fb->zones;
    for (int i = 0; i < 10; i++) {
        int x1 = (int16_t)zs[i].x1;
        int btn_w = (int16_t)zs[i].x2 - x1;
        if (btn_w < 3) continue;

        bool hov = (int32_t)fb->hovered_id == i;
        ScreenBuffer_set_pen(scr, th->accent_fg, hov ? th->dir_fg : th->accent, ATTR_BOLD);
        (void)ScreenBuffer_draw_text(scr, x1, fb->base.y, f_nums[i], 2);

        int avail = btn_w - 2;
        if (avail <= 1) continue;
        int lbl_w = avail >= 3 ? avail - 1 : avail;

        ScreenBuffer_set_pen(scr, th->badge_fg, hov ? th->badge_hover_bg : th->badge_bg,
                             hov ? ATTR_BOLD : ATTR_NONE);
        ScreenBuffer_draw_text_pad(scr, x1 + 1, fb->base.y, i18n_get()->s[LS_f_labels + i], lbl_w);
    }
}

int FunctionBar_on_mouse(Widget *self, void *event)
{
    FunctionBar *fb = (FunctionBar *)self;
    const Event *ev = (const Event *)event;
    int mx = ev->mouse_x;
    int my = ev->mouse_y;
    int hit = -1;

    const HitZone *zs = (const HitZone *)fb->zones;
    int cnt = (int32_t)fb->zone_count;
    for (int i = 0; i < cnt; i++) {
        if (my == (int16_t)zs[i].y && mx >= (int16_t)zs[i].x1 && mx < (int16_t)zs[i].x2) {
            hit = (int16_t)zs[i].id;
            break;
        }
    }

    if (ev->mouse_kind == MACT_MOVE) {
        if (hit != (int32_t)fb->hovered_id) {
            fb->hovered_id = (uint32_t)hit;
            ((App *)(uintptr_t)fb->app)->need_redraw = 1;
        }
        return 0;
    }
    if (ev->mouse_kind == MACT_PRESS) {
        if (ev->mouse_btn != MOUSE_LEFT || hit == -1) return 0;
        App_dispatch_f_action((App *)(uintptr_t)fb->app, hit);
        return 1;
    }
    return 0;
}
