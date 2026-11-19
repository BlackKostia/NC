/* src/ui/file_pane_rows.c - FilePane hot row renderer: selection/hover/cursor styling,
 * file-type glyph + git marker, filename + ellipsis, right-aligned size/DIR badge, and
 * mtime/perms column (freestanding C23; split from src/ui/file_pane_render.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void fp_draw_row_extra(FilePane *fp, ScreenBuffer *scr, const FileEntry *e,
                              const FilePaneCols *cols, int ry)
{
    uint32_t flags = e->flags;
    if (cols->extra_w <= 0 || (flags & FE_IS_PARENT)) return;
    char aux[32];
    if (cols->extra_is_date) format_datetime(e->mtime, aux);
    else format_perms(e->mode, aux);
    (void)ScreenBuffer_draw_text(scr, fp->base.x + 1 + cols->name_w + cols->size_w + 1,
                                 ry, aux, cols->extra_w - 1);
}

static void fp_draw_row_cols(FilePane *fp, ScreenBuffer *scr, const Theme *th,
                             const FileEntry *e, const FilePaneCols *cols,
                             int ry, int idx, uint32_t fg, uint32_t bg, uint32_t attrs)
{
    if (cols->size_w <= 0) return;
    uint32_t flags = e->flags;
    uint32_t sfg = ((flags & FE_SELECTED) || idx == (int32_t)fp->cursor) ? fg : th->muted;
    ScreenBuffer_set_pen(scr, sfg, bg, attrs);

    char aux[32];
    if (flags & FE_IS_DIR) (void)str_copy(aux, i18n_get()->s[LS_fp_dir_badge], sizeof aux);
    else format_size(e->size, aux);

    int sw = utf8_display_width(aux);
    int shift = cols->size_w - 1 - sw;
    if (shift < 0) shift = 0;
    (void)ScreenBuffer_draw_text(scr, fp->base.x + 1 + cols->name_w + shift, ry, aux, cols->size_w);
    fp_draw_row_extra(fp, scr, e, cols, ry);
}

static void fp_render_one_row(FilePane *fp, DirModel *m, ScreenBuffer *scr, const Theme *th,
                              const FilePaneCols *cols, int r, int focused)
{
    int idx = (int32_t)fp->scroll + r;
    FileEntry *e = DirModel_get_entry(m, idx);
    if (!e) return;

    uint32_t flags = e->flags;
    uint32_t bg = th->surface;
    uint32_t attrs = ATTR_NONE;
    if (idx == (int32_t)fp->cursor) {
        bg = focused ? th->cursor_active_bg : th->cursor_inactive_bg;
        if (focused) attrs = ATTR_BOLD;
    } else if (r == (int32_t)fp->hovered_row) bg = th->surface_alt;
    else if (flags & FE_SELECTED) bg = th->selected_bg;

    uint32_t fg = th->text;
    if (flags & FE_SELECTED) { fg = th->selected_fg; attrs |= ATTR_BOLD; }
    else if (flags & (FE_IS_DIR | FE_LINK_DIR)) { fg = th->dir_fg; attrs |= ATTR_BOLD; }
    else if (flags & FE_IS_LINK) fg = th->link_fg;
    else if (flags & FE_IS_EXEC) fg = th->exec_fg;
    else if (flags & FE_IS_HIDDEN) fg = th->hidden_fg;

    int ry = fp->base.y + 3 + r;
    ScreenBuffer_set_pen(scr, fg, bg, attrs);
    ScreenBuffer_draw_hline(scr, fp->base.x + 1, ry, fp->base.w - 2, ' ');
    if (flags & FE_SELECTED) ScreenBuffer_set_cell_pen(scr, fp->base.x + 1, ry, CH_CHECK);

    uint32_t glyph = CH_SQ_SMALL;
    if (flags & FE_IS_PARENT) glyph = CH_LAQUO;
    else if (flags & FE_IS_LINK) glyph = CH_ARROW_NE;
    else if (flags & FE_IS_DIR) glyph = CH_TRI_RIGHT;
    else if (flags & FE_IS_EXEC) glyph = CH_DIAMOND;
    fp_draw_glyph_and_git(scr, fp->base.x + 3, ry, glyph, fp, e, th, bg);

    int nw = cols->name_w - 5;
    if (nw < 1) nw = 1;
    (void)ScreenBuffer_draw_text(scr, fp->base.x + 5, ry, DirModel_entry_name(m, e), nw);
    if ((int)e->disp_width > cols->name_w - 5)
        ScreenBuffer_set_cell_pen(scr, fp->base.x + cols->name_w, ry, CH_ELLIPSIS);

    fp_draw_row_cols(fp, scr, th, e, cols, ry, idx, fg, bg, attrs);
}

void fp_render_rows(FilePane *fp, ScreenBuffer *scr, const Theme *th,
                    const FilePaneCols *cols, int list_h, int focused)
{
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    DirModel_stat_range(m, fp->scroll, (size_t)list_h);
    for (int r = 0; r < list_h; r++)
        fp_render_one_row(fp, m, scr, th, cols, r, focused);
}
