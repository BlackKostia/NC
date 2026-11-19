/* src/ui/file_pane_render.c - FilePane frame, path pill / tab strip, divider,
 * column headers, scrollbar, and footer summary / filter badge renderer
 * (freestanding C23; replaces src/ui/file_pane_render.s together with file_pane_rows.c,
 * kept as tests/harness/file_pane_render_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void fp_draw_title_pill(FilePane *fp, ScreenBuffer *scr, const Theme *th, int focused)
{
    const DirModel *m = (const DirModel *)(uintptr_t)fp->model;
    const char *path = m->path;
    size_t plen = str_len(path);
    int max_p = fp->base.w - 12;
    if (max_p < 4) max_p = 4;

    char buf[128];
    buf[0] = ' ';
    buf[1] = 0;
    if (plen > (size_t)max_p) {
        (void)str_cat(buf, "\xe2\x80\xa6", 128);
        (void)str_cat(buf, path + (plen - (size_t)max_p + 1), 128);
    } else {
        (void)str_cat(buf, path, 128);
    }
    size_t bl = str_len(buf);
    if (bl < 126) { buf[bl] = ' '; buf[bl + 1] = 0; }

    ScreenBuffer_set_pen(scr, focused ? th->accent_fg : th->border_inactive,
                         focused ? th->accent : th->surface_alt,
                         focused ? ATTR_BOLD : ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, fp->base.x + 2, fp->base.y, buf, fp->base.w - 8);
    fp_draw_search_badge(fp, scr);
}

static void fp_draw_tabs(FilePane *fp, ScreenBuffer *scr, const Theme *th, int focused)
{
    NavTab *act = fp_get_active_tab(fp);
    if (!act) return;
    const DirModel *m = (const DirModel *)(uintptr_t)fp->model;
    (void)str_copy(act->path, m->path, PATH_MAX);

    const NavTab *tabs = (const NavTab *)(uintptr_t)fp->tabs;
    int cur_x = fp->base.x + 2;
    int limit_x = fp->base.x + fp->base.w - 4;
    for (int t = 0; t < (int32_t)fp->tab_count && cur_x < limit_x; t++) {
        char buf[128];
        buf[0] = '[';
        buf[1] = (char)('1' + t);
        buf[2] = ':';
        buf[3] = 0;
        const char *bn = path_basename(tabs[t].path);
        if (!bn || !bn[0]) { buf[3] = '/'; buf[4] = 0; }
        else (void)str_cat(buf, bn, 22);
        size_t bl = str_len(buf);
        if (bl < 125) { buf[bl] = ']'; buf[bl + 1] = 0; bl++; }

        if (t == (int32_t)fp->active_tab) {
            ScreenBuffer_set_pen(scr, focused ? th->accent_fg : th->text,
                                 focused ? th->accent : th->surface_alt, ATTR_BOLD);
        } else {
            ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
        }
        (void)ScreenBuffer_draw_text(scr, cur_x, fp->base.y, buf, 24);

        int dw = utf8_display_width(buf);
        if (dw == 0) dw = (int)bl;
        if ((int32_t)fp->tab_zone_count < NAV_TAB_MAX) {
            HitZone *z = &((HitZone *)fp->tab_zones)[fp->tab_zone_count++];
            z->x1 = (uint16_t)cur_x;
            z->y = (uint16_t)fp->base.y;
            z->x2 = (uint16_t)(cur_x + dw);
            z->id = (uint16_t)t;
        }
        cur_x += dw + 1;
    }
}

static void fp_prep_col_hdr(const FilePane *fp, ScreenBuffer *scr, const Theme *th,
                            int sort_id, const char *label, char *buf)
{
    const DirModel *m = (const DirModel *)(uintptr_t)fp->model;
    uint32_t fg = (m->sort_mode == sort_id) ? th->accent : th->muted;
    uint32_t bg = th->surface;
    uint32_t attr = ATTR_BOLD;
    if ((int32_t)fp->hovered_col_hdr == sort_id) {
        bg = th->surface_alt;
        attr |= ATTR_UNDERLINE;
    }
    ScreenBuffer_set_pen(scr, fg, bg, attr);
    (void)str_copy(buf, label, 128);
    if (!m->is_unsorted && m->sort_mode == sort_id)
        (void)str_cat(buf, m->sort_desc ? " \xe2\x96\xbc" : " \xe2\x96\xb2", 128);
}

static void fp_draw_headers(const FilePane *fp, ScreenBuffer *scr, const Theme *th,
                            const FilePaneCols *cols)
{
    const LangStrings *ls = i18n_get();
    char buf[128];
    int hy = fp->base.y + 1;

    fp_prep_col_hdr(fp, scr, th, SORT_NAME, ls->s[LS_fp_col_name], buf);
    ScreenBuffer_draw_hline(scr, fp->base.x + 1, hy, 4, ' ');
    ScreenBuffer_draw_text_pad(scr, fp->base.x + 5, hy, buf, cols->name_w - 4);
    if (cols->size_w <= 0) return;

    fp_prep_col_hdr(fp, scr, th, SORT_SIZE, ls->s[LS_fp_col_size], buf);
    ScreenBuffer_draw_text_pad(scr, fp->base.x + 1 + cols->name_w, hy, buf, cols->size_w);
    if (cols->extra_w <= 0) return;

    int ex_id = cols->extra_is_date ? SORT_MTIME : SORT_EXT;
    const char *ex_lbl = cols->extra_is_date ? ls->s[LS_fp_col_mod] : ls->s[LS_fp_col_perm];
    fp_prep_col_hdr(fp, scr, th, ex_id, ex_lbl, buf);
    ScreenBuffer_draw_text_pad(scr, fp->base.x + 1 + cols->name_w + cols->size_w + 1,
                               hy, buf, cols->extra_w - 1);
}

static void fp_draw_scrollbar(const FilePane *fp, const DirModel *m, ScreenBuffer *scr,
                              const Theme *th, int list_h)
{
    if (m->count <= (uint64_t)(uint32_t)list_h) return;
    uint32_t cnt = (uint32_t)m->count;
    uint32_t lh = (uint32_t)list_h;
    uint32_t thumb_h = (lh * lh) / cnt;
    if (thumb_h < 1) thumb_h = 1;
    uint32_t max_scr = cnt > lh ? cnt - lh : 1;
    uint32_t ts = (fp->scroll * (lh - thumb_h)) / max_scr;
    uint32_t te = ts + thumb_h;

    int sx = fp->base.x + fp->base.w - 1;
    int sy = fp->base.y + 3;
    for (uint32_t r = 0; r < lh; r++) {
        bool in = (r >= ts && r < te);
        ScreenBuffer_set_pen(scr, in ? th->scroll_thumb : th->scroll_track, th->surface, ATTR_NONE);
        ScreenBuffer_set_cell_pen(scr, sx, sy + (int)r, in ? CH_BLOCK_FULL : CH_SHADE_LIGHT);
    }
}

static void fp_draw_footer(const FilePane *fp, DirModel *m, ScreenBuffer *scr, const Theme *th)
{
    const LangStrings *ls = i18n_get();
    char buf[128], aux[32];
    int64_t sel_bytes = 0;
    size_t sel_cnt = DirModel_count_selected(m, &sel_bytes);

    if (sel_cnt > 0) {
        (void)str_copy(buf, ls->s[LS_fp_sel_pfx], sizeof buf);
        u64_to_dec((uint64_t)sel_cnt, aux);
        (void)str_cat(buf, aux, sizeof buf);
        (void)str_cat(buf, ls->s[LS_fp_sel_mid], sizeof buf);
        format_size(sel_bytes, aux);
        (void)str_cat(buf, aux, sizeof buf);
        (void)str_cat(buf, ls->s[LS_fp_sel_end], sizeof buf);
        ScreenBuffer_set_pen(scr, th->selected_fg, th->surface, ATTR_BOLD);
    } else {
        buf[0] = ' ';
        buf[1] = 0;
        u64_to_dec((uint32_t)m->dir_count, aux);
        (void)str_cat(buf, aux, sizeof buf);
        (void)str_cat(buf, ls->s[LS_fp_sum_dirs], sizeof buf);
        u64_to_dec((uint32_t)m->file_count, aux);
        (void)str_cat(buf, aux, sizeof buf);
        (void)str_cat(buf, ls->s[LS_fp_sum_files], sizeof buf);
        format_size((int64_t)m->total_bytes, aux);
        (void)str_cat(buf, aux, sizeof buf);
        if (m->is_loading) {
            (void)str_cat(buf, ls->s[LS_fp_loading_pfx], sizeof buf);
            u64_to_dec(m->raw_count, aux);
            (void)str_cat(buf, aux, sizeof buf);
        } else if (m->load_aborted) {
            (void)str_cat(buf, ls->s[LS_fp_abort_badge], sizeof buf);
        } else if (m->huge_mode && m->is_unsorted) {
            (void)str_cat(buf, ls->s[LS_fp_huge_badge], sizeof buf);
        }
        ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
    }
    ScreenBuffer_draw_text_pad(scr, fp->base.x + 1, fp->base.y + fp->base.h - 2, buf, fp->base.w - 2);

    if (!m->filter[0]) return;
    (void)str_copy(buf, ls->s[LS_fp_flt_tag], sizeof buf);
    (void)str_cat(buf, m->filter, sizeof buf);
    size_t bl = str_len(buf);
    if (bl < 126) { buf[bl] = ' '; buf[bl + 1] = 0; }
    ScreenBuffer_set_pen(scr, th->accent_fg, th->warn_fg, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, fp->base.x + 2, fp->base.y + fp->base.h - 1, buf, fp->base.w - 4);
}

void FilePane_render(Widget *self, void *screen, void *theme)
{
    FilePane *fp = (FilePane *)self;
    if (fp->base.w < 6 || fp->base.h < 6) return;

    ScreenBuffer *scr = (ScreenBuffer *)screen;
    const Theme *th = (const Theme *)theme;
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    int focused = (fp->base.flags & WF_FOCUSED) != 0;
    uint32_t border_fg = focused ? th->border_active : th->border_inactive;
    FilePaneCols cols = file_pane_compute_cols(fp->base.w);
    int list_h = get_list_h(fp);

    ScreenBuffer_set_pen(scr, border_fg, th->surface, ATTR_NONE);
    ScreenBuffer_draw_box(scr, fp->base.x, fp->base.y, fp->base.w, fp->base.h, 1);

    fp->tab_zone_count = 0;
    if ((int32_t)fp->tab_count > 1) fp_draw_tabs(fp, scr, th, focused);
    else fp_draw_title_pill(fp, scr, th, focused);

    ScreenBuffer_set_pen(scr, border_fg, th->surface, ATTR_NONE);
    ScreenBuffer_set_cell_pen(scr, fp->base.x, fp->base.y + 2, CH_BOX_LT);
    ScreenBuffer_draw_hline(scr, fp->base.x + 1, fp->base.y + 2, fp->base.w - 2, CH_BOX_H);
    ScreenBuffer_set_cell_pen(scr, fp->base.x + fp->base.w - 1, fp->base.y + 2, CH_BOX_RT);

    fp_draw_headers(fp, scr, th, &cols);
    fp_render_rows(fp, scr, th, &cols, list_h, focused);
    fp_draw_du_pane(fp, scr, th);
    fp_draw_scrollbar(fp, m, scr, th, list_h);
    fp_draw_footer(fp, m, scr, th);
}
