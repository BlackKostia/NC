/* src/ui/conflict_dialog.c - File Conflict Dialog ([ Overwrite ] / [ Skip ] / [ Rename ] / [ For all ])
 * (freestanding C23; replaces src/ui/conflict_dialog{,_input}.s, kept as
 * tests/harness/conflict_dialog{,_input}_reference.s). */
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_task.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void ConflictDialog_layout(Widget *self, int x, int y, int w, int h);
static void ConflictDialog_render(Widget *self, void *screen, void *theme);
static int ConflictDialog_on_key(Widget *self, void *event);
static int ConflictDialog_on_mouse(Widget *self, void *event);

DIALOG_VTBL(ConflictDialog_vtbl, "ConflictDialog", Dialog_vtbl, sizeof(ConflictDialog),
            .base.layout = ConflictDialog_layout, .base.render = ConflictDialog_render,
            .base.on_key = ConflictDialog_on_key, .base.on_mouse = ConflictDialog_on_mouse);

ConflictDialog *ConflictDialog_new(App *app, const char *name, uint64_t src_sz, uint64_t dst_sz)
{
    ConflictDialog *cd = DUOP_NEW(ConflictDialog, ConflictDialog_vtbl);
    if (!cd) return nullptr;

    Dialog_init(&cd->base, app, i18n_get()->s[LS_dlg_title_conflict], OP_CONFLICT);
    cd->action = CONFLICT_ACT_OVERWRITE;
    cd->for_all = 0;
    cd->src_size = src_sz;
    cd->dst_size = dst_sz;
    cd->base.focus_btn = 0;
    cd->base.btn_count = 3;
    (void)str_copy((char *)cd->name, name, sizeof cd->name);

    ConflictDialog_layout(&cd->base.base, 0, 0, (int)app->term_w, (int)app->term_h);
    return cd;
}

static void ConflictDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 4;
    if (dw > 68) dw = 68;
    if (dw < 44) dw = 44;

    self->w = dw;
    self->h = 11;
    self->x = (w - dw) >> 1;
    self->y = (h - 11) >> 1;
}

static void cfl_draw_buttons(ConflictDialog *cd, ScreenBuffer *scr, const Theme *th, const LangStrings *ls)
{
    const char *labels[3] = {
        ls->s[LS_cfl_btn_overwrite],
        ls->s[LS_cfl_btn_skip],
        ls->s[LS_cfl_btn_rename],
    };
    int bx = cd->base.base.x + 3;
    int by = cd->base.base.y + 6;
    HitZone *z = (HitZone *)cd->base.btns;
    cd->base.btn_count = 3;

    for (int i = 0; i < 3; i++) {
        if (i == (int)cd->base.focus_btn)
            ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_BOLD);
        else
            ScreenBuffer_set_pen(scr, th->text, th->surface_alt, ATTR_NONE);

        int bw = (int)utf8_display_width(labels[i]) + 2;
        z[i].x1 = (int16_t)bx;
        z[i].y = (int16_t)by;
        z[i].x2 = (int16_t)(bx + bw);
        z[i].id = (int16_t)i;

        (void)ScreenBuffer_draw_text(scr, bx, by, " ", 2);
        (void)ScreenBuffer_draw_text(scr, bx + 1, by, labels[i], 24);
        (void)ScreenBuffer_draw_text(scr, bx + bw - 1, by, " ", 2);
        bx += bw + 2;
    }
}

static void ConflictDialog_render(Widget *self, void *screen, void *theme)
{
    (void)theme;
    ConflictDialog *cd = (ConflictDialog *)self;
    ScreenBuffer *scr = screen;
    const App *app = (const App *)(uintptr_t)cd->base.app;
    const Theme *th = (const Theme *)(uintptr_t)app->theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(&cd->base, scr, th, nullptr, nullptr);

    ScreenBuffer_set_pen(scr, th->text, th->surface, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, cd->base.base.x + 3, cd->base.base.y + 2,
                                 (const char *)cd->name, cd->base.base.w - 6);

    ScreenBuffer_set_pen(scr, th->accent, th->surface, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, cd->base.base.x + 3, cd->base.base.y + 4,
                                 cd->for_all ? "[x] " : "[ ] ", 6);
    (void)ScreenBuffer_draw_text(scr, cd->base.base.x + 7, cd->base.base.y + 4,
                                 ls->s[LS_cfl_lbl_forall], 24);

    cfl_draw_buttons(cd, scr, th, ls);

    ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, cd->base.base.x + 3, cd->base.base.y + 8,
                                 ls->s[LS_cfl_hint], cd->base.base.w - 6);
}

static int ConflictDialog_on_key(Widget *self, void *event)
{
    ConflictDialog *cd = (ConflictDialog *)self;
    App *app = (App *)(uintptr_t)cd->base.app;
    const Event *ev = event;

    switch (ev->lat) {
    case KEY_ESC:
        Dialog_on_cancel(&cd->base);
        return 1;
    case 'a':
    case 'A':
        cd->for_all ^= 1;
        app->need_redraw = 1;
        return 1;
    case 'o':
    case 'O':
        cd->action = CONFLICT_ACT_OVERWRITE;
        Dialog_on_confirm(&cd->base);
        return 1;
    case 's':
    case 'S':
        cd->action = CONFLICT_ACT_SKIP;
        Dialog_on_confirm(&cd->base);
        return 1;
    case 'r':
    case 'R':
        cd->action = CONFLICT_ACT_RENAME;
        Dialog_on_confirm(&cd->base);
        return 1;
    case KEY_LEFT: {
        int fb = (int)cd->base.focus_btn - 1;
        if (fb < 0) fb = 2;
        cd->base.focus_btn = (uint32_t)fb;
        app->need_redraw = 1;
        return 1;
    }
    case KEY_RIGHT:
    case KEY_TAB: {
        int fb = (int)cd->base.focus_btn + 1;
        if (fb >= 3) fb = 0;
        cd->base.focus_btn = (uint32_t)fb;
        app->need_redraw = 1;
        return 1;
    }
    case KEY_ENTER:
        cd->action = cd->base.focus_btn + 1;
        Dialog_on_confirm(&cd->base);
        return 1;
    default:
        return 0;
    }
}

static int ConflictDialog_on_mouse(Widget *self, void *event)
{
    ConflictDialog *cd = (ConflictDialog *)self;
    App *app = (App *)(uintptr_t)cd->base.app;
    const Event *ev = event;
    if (ev->mouse_kind != MACT_PRESS) return 0;

    if (ev->mouse_y == cd->base.base.y + 4) {
        cd->for_all ^= 1;
        app->need_redraw = 1;
        return 1;
    }

    const HitZone *z = (const HitZone *)cd->base.btns;
    for (int i = 0; i < 3; i++) {
        if (ev->mouse_y == (int16_t)z[i].y &&
            ev->mouse_x >= (int16_t)z[i].x1 &&
            ev->mouse_x < (int16_t)z[i].x2) {
            cd->action = (uint32_t)((int16_t)z[i].id + 1);
            Dialog_on_confirm(&cd->base);
            return 1;
        }
    }
    return 0;
}
