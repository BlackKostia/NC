/* src/ui/du_progress_dlg.c - DuProgressDialog (Inherits from Dialog): the "Scanning disk usage"
 * modal shown while a Disk Usage walk runs (freestanding C23; replaces src/ui/du_progress_dlg.s,
 * kept as tests/harness/du_progress_dlg_reference.s). */
#include "duop_classes.h"
#include "duop_du.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define DPD_W_MAX 64
#define DPD_W_MIN 40
#define DPD_H 9
#define DPD_BUF 192

static void DuProgressDialog_render(Widget *self, void *screen, void *theme);

DIALOG_VTBL(DuProgressDialog_vtbl, "DuProgressDialog", Dialog_vtbl, sizeof(Dialog),
            .base.layout = DuProgressDialog_layout, .base.render = DuProgressDialog_render);

Dialog *DuProgressDialog_new(App *app)
{
    Dialog *d = DUOP_NEW(Dialog, DuProgressDialog_vtbl);
    if (!d) return nullptr;
    Dialog_init(d, app, i18n_get()->s[LS_du_scan_title], 0);
    DuProgressDialog_layout(&d->base, 0, 0, (int)app->term_w, (int)app->term_h);
    return d;
}

void DuProgressDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 4;
    if (dw > DPD_W_MAX) dw = DPD_W_MAX;
    if (dw < DPD_W_MIN) dw = DPD_W_MIN;
    self->w = dw;
    self->h = DPD_H;
    self->x = (w - dw) >> 1;
    self->y = (h - DPD_H) >> 1;
}

static void dpd_cat_u64(char *buf, uint64_t v)
{
    char tmp[32];
    (void)u64_to_dec(v, tmp);
    (void)str_cat(buf, tmp, DPD_BUF);
}

static void dpd_cat_count(char *buf, uint64_t v, const char *unit)
{
    dpd_cat_u64(buf, v);
    (void)str_cat(buf, " ", DPD_BUF);
    (void)str_cat(buf, unit, DPD_BUF);
}

static void dpd_text_at(const Dialog *d, ScreenBuffer *scr, const char *text, int row)
{
    (void)ScreenBuffer_draw_text(scr, d->base.x + 3, d->base.y + row, text, d->base.w - 6);
}

static void dpd_draw_folders(const Dialog *d, ScreenBuffer *scr, const Theme *th,
                             const DuProgress *p, const LangStrings *ls)
{
    char line[DPD_BUF];
    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_BOLD);
    (void)str_copy(line, ls->s[LS_du_lbl_folders], DPD_BUF);
    (void)str_cat(line, "  ", DPD_BUF);
    dpd_cat_u64(line, (uint32_t)p->done);
    (void)str_cat(line, " / ", DPD_BUF);
    dpd_cat_u64(line, (uint32_t)p->total);
    dpd_text_at(d, scr, line, 2);
}

static void dpd_draw_bar(const Dialog *d, ScreenBuffer *scr, const Theme *th, const DuProgress *p)
{
    int bar_w = d->base.w - 6;
    uint32_t total = (uint32_t)p->total;
    uint32_t filled = 0;
    if (total) {
        uint32_t q = ((uint32_t)p->done * (uint32_t)bar_w) / total;
        if (q <= (uint32_t)bar_w) filled = q;
    }
    ScreenBuffer_set_pen(scr, th->accent, th->dialog_bg, ATTR_NONE);
    ScreenBuffer_fill_rect(scr, d->base.x + 3, d->base.y + 3, (int)filled, 1, CH_BLOCK_FULL);
    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    ScreenBuffer_fill_rect(scr, d->base.x + 3 + (int)filled, d->base.y + 3, bar_w - (int)filled, 1, CH_SHADE_LIGHT);
}

static void dpd_draw_scanned(const Dialog *d, ScreenBuffer *scr, const Theme *th,
                             const DuProgress *p, const LangStrings *ls)
{
    char line[DPD_BUF], sz[32];
    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);
    (void)str_copy(line, ls->s[LS_du_lbl_scanned], DPD_BUF);
    (void)str_cat(line, "  ", DPD_BUF);
    dpd_cat_count(line, p->dirs, ls->s[LS_du_unit_dirs]);
    (void)str_cat(line, " · ", DPD_BUF);
    dpd_cat_count(line, p->files, ls->s[LS_du_unit_files]);
    (void)str_cat(line, " · ", DPD_BUF);
    (void)format_size((int64_t)p->bytes, sz);
    (void)str_cat(line, sz, DPD_BUF);
    dpd_text_at(d, scr, line, 4);
}

static void DuProgressDialog_render(Widget *self, void *screen, void *theme)
{
    (void)theme;
    Dialog *d = (Dialog *)self;
    ScreenBuffer *scr = screen;
    const App *app = (const App *)(uintptr_t)d->app;
    const Theme *th = (const Theme *)(uintptr_t)app->theme;
    const DuProgress *p = du_progress();
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(d, scr, th, nullptr, nullptr);
    dpd_draw_folders(d, scr, th, p, ls);
    dpd_draw_bar(d, scr, th, p);
    dpd_draw_scanned(d, scr, th, p, ls);

    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    dpd_text_at(d, scr, ls->s[LS_du_scan_hint], 6);
}
