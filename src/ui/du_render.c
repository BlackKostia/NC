/* src/ui/du_render.c - Disk Usage (ncdu) badge & TrueColor percentage bar renderer
 * (freestanding C23; replaces du_render.s, kept as tests/harness/du_render_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

void fp_draw_du_badge(FilePane *fp, ScreenBuffer *sb)
{
    const DirModel *dm = (const DirModel *)(uintptr_t)fp->model;
    if (!dm || dm->du_mode == 0) return;

    const App *app = (const App *)(uintptr_t)fp->app;
    const Theme *th = theme_get(app ? (int)app->theme_idx : 0);
    const char *badge = i18n_get()->s[LS_fp_du_badge];
    int bw = utf8_display_width(badge);

    ScreenBuffer_set_pen(sb, th->accent_fg, th->accent, ATTR_BOLD);
    int x = fp->base.x + fp->base.w - bw - 3;
    if (x <= fp->base.x) return;
    (void)ScreenBuffer_draw_text(sb, x, fp->base.y, badge, bw);
}

static uint64_t du_percent(uint64_t size, uint64_t total)
{
    if (total == 0) return 0;
    if (size >= total) return 100;
    if (size <= UINT64_MAX / 100u) return (size * 100u) / total;
    return size / (total / 100u);
}

static void du_draw_row(const FilePane *fp, ScreenBuffer *sb, const Theme *th,
                        const DirModel *dm, const FileEntry *e, uint32_t idx, int row)
{
    uint32_t bg = th->surface;
    if (idx == fp->cursor)
        bg = (fp->base.flags & WF_FOCUSED) ? th->cursor_active_bg : th->cursor_inactive_bg;

    int y = fp->base.y + 3 + row;
    int rx = fp->base.x + fp->base.w;

    ScreenBuffer_set_pen(sb, th->text, bg, ATTR_NONE);
    ScreenBuffer_fill_rect(sb, rx - 27, y, 26, 1, ' ');

    char tmp[32];
    (void)format_size(e->size, tmp);
    (void)ScreenBuffer_draw_text(sb, rx - 26, y, tmp, 9);

    uint64_t pct = du_percent(e->size, dm->du_total);
    int filled = (int)((pct * 8u) / 100u);

    ScreenBuffer_set_pen(sb, th->accent, bg, ATTR_NONE);
    for (int i = 0; i < 8; i++)
        ScreenBuffer_set_cell_pen(sb, rx - 16 + i, y, i < filled ? 0x2588u : 0x2591u);

    ScreenBuffer_set_pen(sb, th->muted, bg, ATTR_NONE);
    size_t n = u64_to_dec(pct, tmp);
    tmp[n] = '%';
    tmp[n + 1] = ' ';
    tmp[n + 2] = '\0';
    (void)ScreenBuffer_draw_text(sb, rx - 7, y, tmp, 5);
}

void fp_draw_du_pane(FilePane *fp, ScreenBuffer *sb, const Theme *th)
{
    DirModel *dm = (DirModel *)(uintptr_t)fp->model;
    if (!dm || dm->du_mode == 0) return;

    int list_h = fp->base.h - 5;
    if (list_h < 1) return;

    for (int row = 0; row < list_h; row++) {
        uint64_t idx = (uint64_t)(uint32_t)row + (uint64_t)fp->scroll;
        if (idx >= dm->count) break;
        FileEntry *e = DirModel_get_entry(dm, (int)idx);
        if (!e || (e->flags & FE_IS_PARENT)) continue;
        du_draw_row(fp, sb, th, dm, e, (uint32_t)idx, row);
    }
}
