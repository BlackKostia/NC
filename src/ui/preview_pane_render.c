/* src/ui/preview_pane_render.c - PreviewPane frame rendering: box, title pill, metadata bar,
 * divider, directory/empty/hex/text modes (freestanding C23; replaces src/ui/preview_pane_render.s,
 * kept as tests/harness/preview_pane_render_reference.s). */
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define CH_BOX_LT 0x251Cu
#define CH_BOX_RT 0x2524u

static void ppr_draw_chrome(const Widget *self, const PreviewPane *pv, ScreenBuffer *scr, const Theme *th)
{
    const LangStrings *ls = i18n_get();
    ScreenBuffer_set_pen(scr, th->border_inactive, th->surface, ATTR_NONE);
    ScreenBuffer_draw_box(scr, self->x, self->y, self->w, self->h, 1);

    ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y, ls->s[LS_pv_title], self->w - 4);

    char line[256], aux[32];
    (void)str_copy(line, ls->s[LS_pv_sz_lbl], sizeof line);
    (void)format_size((int64_t)pv->file_size, aux);
    (void)str_cat(line, aux, sizeof line);
    (void)str_cat(line, ls->s[LS_pv_perm_lbl], sizeof line);
    format_perms(pv->file_mode, aux);
    (void)str_cat(line, aux, sizeof line);

    ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y + 1, line, self->w - 4);

    ScreenBuffer_set_pen(scr, th->border_inactive, th->surface, ATTR_NONE);
    ScreenBuffer_set_cell_pen(scr, self->x, self->y + 2, CH_BOX_LT);
    ScreenBuffer_draw_hline(scr, self->x + 1, self->y + 2, self->w - 2, CH_BOX_H);
    ScreenBuffer_set_cell_pen(scr, self->x + self->w - 1, self->y + 2, CH_BOX_RT);
}

static void ppr_render_hex(const Widget *self, const PreviewPane *pv, ScreenBuffer *scr, const Theme *th)
{
    const LangStrings *ls = i18n_get();
    ScreenBuffer_set_pen(scr, th->warn_fg, th->surface, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y + 3, ls->s[LS_pv_bin_hdr], self->w - 4);

    uint64_t off = (uint64_t)pv->scroll << 3;
    int max_rows = self->h - 5;
    const uint8_t *buf = (const uint8_t *)(uintptr_t)pv->buf;
    char line[256], aux[32];

    for (int r = 0; r < max_rows && off < pv->buf_len; r++, off += 8u) {
        (void)u64_to_hex(off, line, 4);
        line[4] = ':';
        line[5] = ' ';
        line[6] = 0;
        for (int c = 0; c < 8; c++) {
            if (off + (uint64_t)c < pv->buf_len) {
                (void)u64_to_hex(buf[off + (uint64_t)c], aux, 2);
                (void)str_cat(line, aux, sizeof line);
                (void)str_cat(line, " ", sizeof line);
            } else {
                (void)str_cat(line, " ", sizeof line);
            }
        }
        ScreenBuffer_set_pen(scr, th->text, th->surface, ATTR_NONE);
        (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y + 4 + r, line, self->w - 4);
    }
}

static void ppr_render_text(const Widget *self, const PreviewPane *pv, ScreenBuffer *scr, const Theme *th)
{
    const char *p = (const char *)(uintptr_t)pv->buf;
    const char *end = p + pv->buf_len;
    int skip = (int)pv->scroll;
    uint32_t line_no = 1;
    while (skip > 0) {
        if (p >= end) return;
        if (*p++ == '\n') { skip--; line_no++; }
    }
    int max_rows = self->h - 4;
    char line[256], num[32];
    for (int r = 0; r < max_rows && p < end; r++, line_no++) {
        (void)u64_to_dec(line_no, num);
        ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
        ScreenBuffer_draw_text_pad(scr, self->x + 2, self->y + 3 + r, num, 5);

        p = pv_copy_line_strip_ansi(p, end, line);
        ScreenBuffer_set_pen(scr, th->text, th->surface, ATTR_NONE);
        (void)ScreenBuffer_draw_text(scr, self->x + 7, self->y + 3 + r, line, self->w - 9);
    }
}

void PreviewPane_render(Widget *self, void *screen, void *theme)
{
    if (self->w < 10 || self->h < 6) return;
    PreviewPane *pv = (PreviewPane *)(void *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    ppr_draw_chrome(self, pv, scr, th);
    if (pv->is_dir) {
        ScreenBuffer_set_pen(scr, th->dir_fg, th->surface, ATTR_BOLD);
        (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y + 4, ls->s[LS_pv_dir_msg], self->w - 4);
        return;
    }
    if (pv->pending) return;
    if (pv->buf_len == 0) {
        ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
        (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y + 4, ls->s[LS_pv_empty], self->w - 4);
        return;
    }
    int kind = pv_mode_dispatch(pv, scr, th);
    if (kind == 0) return;
    if (kind == 2) ppr_render_text(self, pv, scr, th);
    else ppr_render_hex(self, pv, scr, th);
}
