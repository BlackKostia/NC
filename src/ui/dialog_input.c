/* src/ui/dialog_input.c - InputDialog subclass of Dialog (text entry modal)
 * (freestanding C23; replaces src/ui/dialogs_input.s, kept as tests/harness/dialogs_input_reference.s). */
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void InputDialog_layout(Widget *self, int x, int y, int w, int h);
static void InputDialog_render(Widget *self, void *screen, void *theme);

DIALOG_VTBL(InputDialog_vtbl, "InputDialog", Dialog_vtbl, sizeof(InputDialog),
            .base.layout = InputDialog_layout, .base.render = InputDialog_render,
            .base.on_key = InputDialog_on_key);

InputDialog *InputDialog_new(App *app, const char *title, const char *prompt,
                             const char *initial_text, uint32_t op_tag)
{
    InputDialog *id = DUOP_NEW(InputDialog, InputDialog_vtbl);
    if (!id) return nullptr;

    Dialog_init(&id->base, app, title, op_tag);
    (void)str_copy((char *)id->prompt, prompt, sizeof id->prompt);

    if (initial_text) {
        uint64_t n = str_copy((char *)id->buf, initial_text, INPUT_MAX);
        id->len = (uint32_t)n;
        id->cursor = (uint32_t)n;
    }

    InputDialog_layout(&id->base.base, 0, 0, (int)app->term_w, (int)app->term_h);
    return id;
}

static void InputDialog_layout(Widget *self, int x, int y, int w, int h)
{
    int dw = w - 6;
    if (dw > 68) dw = 68;
    if (dw < 36) dw = w;

    int dh = 9;
    if (dh > h) dh = h;

    int dx = x + ((w - dw) >> 1);
    int dy = y + ((h - dh) >> 1);

    Widget_layout(self, dx, dy, dw, dh);
    const LangStrings *ls = i18n_get();
    dlg_layout_center_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);
}

static void InputDialog_render(Widget *self, void *screen, void *theme)
{
    InputDialog *id = (InputDialog *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(&id->base, scr, th, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);

    int field_w = id->base.base.w - 6;
    int fx = id->base.base.x + 3;
    int fy = id->base.base.y + 4;

    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, fx, id->base.base.y + 2,
                                 (const char *)id->prompt, field_w);

    ScreenBuffer_set_pen(scr, th->text, th->surface_alt, ATTR_NONE);
    ScreenBuffer_draw_hline(scr, fx, fy, field_w, ' ');

    int cur = (int)id->cursor;
    int scroll = (int)id->scroll;
    if (cur < scroll)
        scroll = cur;
    else if (cur >= scroll + field_w - 1)
        scroll = cur - field_w + 2;
    if (scroll < 0)
        scroll = 0;
    id->scroll = (uint32_t)scroll;

    (void)ScreenBuffer_draw_text(scr, fx, fy, (const char *)(id->buf + id->scroll), field_w);

    int rel = (int)id->cursor - (int)id->scroll;
    if (rel >= 0 && rel < field_w) {
        uint32_t ch = id->cursor < INPUT_MAX ? (uint32_t)id->buf[id->cursor] : 0;
        if (ch == 0) ch = ' ';
        ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_BOLD);
        ScreenBuffer_set_cell_pen(scr, fx + rel, fy, ch);
    }
}
