/* src/ui/git_render.c - Git branch badge (HeaderBar) & status column (FilePane)
 * (freestanding C23; replaces git_render.s, kept as tests/harness/git_render_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"

void fp_draw_glyph_and_git(ScreenBuffer *scr, int x3, int y, uint32_t glyph,
                           FilePane *fp, FileEntry *ent, const Theme *theme, uint32_t row_bg)
{
    ScreenBuffer_set_cell_pen(scr, x3, y, glyph);

    DirModel *dm = (DirModel *)(uintptr_t)fp->model;
    const char *name = DirModel_entry_name(dm, ent);
    if (!name) return;

    int st = git_lookup(dm, name);
    if (!st) return;

    uint32_t fg = theme->warn_fg;
    if (st == 'A') fg = theme->ok_fg;
    else if (st == '?') fg = theme->muted;
    else if (st == 'D') fg = theme->err_fg;

    ScreenBuffer_set_pen(scr, fg, row_bg, ATTR_BOLD);
    ScreenBuffer_set_cell_pen(scr, x3 - 1, y, (uint32_t)st);
}

void hdr_draw_git_badge(void *hdr, void *scr, const void *theme, int x, int y)
{
    const HeaderBar *hb = hdr;
    ScreenBuffer *s = scr;
    const Theme *t = theme;

    const App *app = (const App *)(uintptr_t)hb->app;
    if (!app) return;
    const FilePane *fp = (const FilePane *)(uintptr_t)app->active_pane;
    if (!fp) return;

    const char *br = git_branch((DirModel *)(uintptr_t)fp->model);
    if (!br || !br[0]) return;

    char buf[72];
    (void)str_copy(buf, " [", sizeof buf);
    (void)str_cat(buf, br, sizeof buf);
    (void)str_cat(buf, "]", sizeof buf);

    ScreenBuffer_set_pen(s, t->badge_fg, t->badge_bg, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(s, x, y, buf, (int)str_len(buf));
}
