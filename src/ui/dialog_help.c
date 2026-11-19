/* src/ui/dialog_help.c - HelpDialog (Inherits from Dialog): two-tab scrollable help viewer
 * (Overview + Instruction) with section-heading highlights and Close button (freestanding C23;
 * replaces src/ui/dialogs_help.s + src/ui/dialogs_help_input.s, kept as tests/harness/dialogs_help*_reference.s). */
#include "duop_classes.h"
#include "duop_keys.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define HELP_LINE_COUNT 22
#define HELP_INSTR_COUNT 36

static void HelpDialog_layout(Widget *self, int x, int y, int w, int h);
static void HelpDialog_render(Widget *self, void *screen, void *theme);
static int HelpDialog_on_key(Widget *self, void *event);
static int HelpDialog_on_mouse(Widget *self, void *event);

DIALOG_VTBL(HelpDialog_vtbl, "HelpDialog", Dialog_vtbl, sizeof(HelpDialog),
            .base.layout = HelpDialog_layout, .base.render = HelpDialog_render,
            .base.on_key = HelpDialog_on_key, .base.on_mouse = HelpDialog_on_mouse,
            .on_confirm = Dialog_on_cancel, .on_cancel = Dialog_on_cancel);

static int help_active_count(const HelpDialog *d)
{
    return d->tab ? HELP_INSTR_COUNT : HELP_LINE_COUNT;
}

static int help_max_scroll(const HelpDialog *d)
{
    int vis = d->base.base.h - 4;
    if (vis < 1) vis = 1;
    int mx = help_active_count(d) - vis;
    return mx > 0 ? mx : 0;
}

static void help_layout_tabs(HelpDialog *d)
{
    const LangStrings *ls = i18n_get();
    HitZone *tz = (HitZone *)(void *)d->tab_zones;
    int cx = d->base.base.x + 3;
    int ty = d->base.base.y + 1;
    int w0 = utf8_display_width(ls->s[LS_help_tab_overview]);
    tz[0].x1 = (int16_t)cx;
    tz[0].x2 = (int16_t)(cx + w0);
    tz[0].y = (int16_t)ty;
    tz[0].id = 0;
    cx += w0 + 2;
    int w1 = utf8_display_width(ls->s[LS_help_tab_instr]);
    tz[1].x1 = (int16_t)cx;
    tz[1].x2 = (int16_t)(cx + w1);
    tz[1].y = (int16_t)ty;
    tz[1].id = 1;
}

HelpDialog *HelpDialog_new(App *app)
{
    HelpDialog *d = DUOP_NEW(HelpDialog, HelpDialog_vtbl);
    if (!d) return nullptr;
    Dialog_init(&d->base, app, i18n_get()->s[LS_dlg_title_help], 0);
    HelpDialog_layout(&d->base.base, 0, 0, (int)app->term_w, (int)app->term_h);
    return d;
}

static void HelpDialog_layout(Widget *self, int x, int y, int w, int h)
{
    HelpDialog *d = (HelpDialog *)self;
    int dw = w - 6;
    if (dw > 78) dw = 78;
    if (dw < 40) dw = w;
    int dh = HELP_LINE_COUNT + 4;
    if (dh > h) dh = h;
    Widget_layout(self, x + ((w - dw) >> 1), y + ((h - dh) >> 1), dw, dh);
    int ms = help_max_scroll(d);
    if ((int)d->scroll > ms) d->scroll = (uint32_t)ms;
    dlg_layout_right_buttons(&d->base, i18n_get()->s[LS_dlg_btn_close], nullptr);
    help_layout_tabs(d);
}

static void help_draw_tabs(const HelpDialog *d, ScreenBuffer *scr, const Theme *th, const LangStrings *ls)
{
    const HitZone *tz = (const HitZone *)(const void *)d->tab_zones;
    for (int i = 0; i < 2; i++) {
        if (i == (int)d->tab) ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_BOLD);
        else ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
        const char *lbl = i == 0 ? ls->s[LS_help_tab_overview] : ls->s[LS_help_tab_instr];
        int x1 = (int16_t)tz[i].x1;
        (void)ScreenBuffer_draw_text(scr, x1, (int16_t)tz[i].y, lbl, (int16_t)tz[i].x2 - x1);
    }
}

static void HelpDialog_render(Widget *self, void *screen, void *theme)
{
    HelpDialog *d = (HelpDialog *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(&d->base, scr, th, ls->s[LS_dlg_btn_close], nullptr);

    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    const HitZone *bz = (const HitZone *)(const void *)d->base.btns;
    int room = (int16_t)bz[0].x1 - (self->x + 4);
    if (room > 0)
        (void)ScreenBuffer_draw_text(scr, self->x + 3, self->y + self->h - 2, ls->s[LS_dlg_hlp_hint], room);

    help_draw_tabs(d, scr, th, ls);

    int vis = self->h - 4;
    int cnt = help_active_count(d);
    int base = d->tab ? LS_help_instr_lines : LS_help_lines;
    for (int r = 0; r < vis; r++) {
        int idx = (int)d->scroll + r;
        if (idx >= cnt) break;
        const char *line = ls->s[base + idx];
        if ((unsigned char)line[0] == 0xE2) ScreenBuffer_set_pen(scr, th->accent, th->dialog_bg, ATTR_BOLD);
        else ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);
        (void)ScreenBuffer_draw_text(scr, self->x + 3, self->y + 2 + r, line, self->w - 6);
    }
}

static int HelpDialog_on_key(Widget *self, void *event)
{
    HelpDialog *d = (HelpDialog *)self;
    const Event *ev = event;
    switch (ev->lat) {
    case KEY_ESC: case KEY_ENTER: case 'q': case KEY_F1:
        DIALOG_CALL(&d->base, on_cancel);
        return 1;
    case KEY_TAB: case KEY_BTAB:
        d->tab ^= 1;
        d->scroll = 0;
        break;
    case KEY_LEFT: case '1':
        d->tab = 0;
        d->scroll = 0;
        break;
    case KEY_RIGHT: case '2':
        d->tab = 1;
        d->scroll = 0;
        break;
    case KEY_UP: {
        int sc = (int)d->scroll - 1;
        d->scroll = (uint32_t)(sc < 0 ? 0 : sc);
        break;
    }
    case KEY_DOWN: {
        int ms = help_max_scroll(d);
        if ((int)d->scroll < ms) d->scroll++;
        break;
    }
    case KEY_PGUP: {
        int step = self->h - 5;
        if (step < 1) step = 1;
        int sc = (int)d->scroll - step;
        d->scroll = (uint32_t)(sc < 0 ? 0 : sc);
        break;
    }
    case KEY_PGDN: {
        int ms = help_max_scroll(d);
        int step = self->h - 5;
        if (step < 1) step = 1;
        int sc = (int)d->scroll + step;
        if (sc > ms) sc = ms;
        d->scroll = (uint32_t)sc;
        break;
    }
    case KEY_HOME:
        d->scroll = 0;
        break;
    case KEY_END:
        d->scroll = (uint32_t)help_max_scroll(d);
        break;
    default:
        return 1;
    }
    ((App *)(uintptr_t)d->base.app)->need_redraw = 1;
    return 1;
}

static int help_zone_hit(const HitZone *z, int mx, int my)
{
    return my == (int16_t)z->y && mx >= (int16_t)z->x1 && mx < (int16_t)z->x2;
}

static int HelpDialog_on_mouse(Widget *self, void *event)
{
    HelpDialog *d = (HelpDialog *)self;
    const Event *ev = event;
    if (ev->mouse_kind == MACT_PRESS && ev->mouse_btn == MOUSE_LEFT) {
        const HitZone *tz = (const HitZone *)(const void *)d->tab_zones;
        int tab = -1;
        if (help_zone_hit(&tz[0], ev->mouse_x, ev->mouse_y)) tab = 0;
        else if (help_zone_hit(&tz[1], ev->mouse_x, ev->mouse_y)) tab = 1;
        if (tab >= 0) {
            d->tab = (uint32_t)tab;
            d->scroll = 0;
            ((App *)(uintptr_t)d->base.app)->need_redraw = 1;
            return 1;
        }
        return Dialog_on_mouse(self, event);
    }
    if (ev->mouse_kind != MACT_WHEEL) return Dialog_on_mouse(self, event);
    if (ev->mouse_btn == MOUSE_WHEEL_UP) {
        int sc = (int)d->scroll - 1;
        d->scroll = (uint32_t)(sc < 0 ? 0 : sc);
        ((App *)(uintptr_t)d->base.app)->need_redraw = 1;
    } else {
        int ms = help_max_scroll(d);
        if ((int)d->scroll < ms) {
            d->scroll++;
            ((App *)(uintptr_t)d->base.app)->need_redraw = 1;
        }
    }
    return 1;
}
