/* src/ui/status_bar.c - the StatusBar widget: a timed message, the background-task summary, the filter of an empty listing, or
 * the entry under the cursor (name, size, permissions, date, symlink target) with the key hint on the right (freestanding C23;
 * replaces status_bar.s + status_bar_render.s, kept as tests/harness/status_bar_reference.s and status_bar_render_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define SB_LINE 512
#define SB_HINT_MIN_W 95           /* narrower bars show no key hint */

void StatusBar_render(Widget *self, void *screen, void *theme);
StatusBar *StatusBar_new(App *app);
void StatusBar_set_message(StatusBar *self, const char *msg, int kind, int ttl_ms);
void ProgressDialog_format_summary(const void *snap, char *buf);    /* src/ui/progress_dialog.s */

WIDGET_VTBL(StatusBar_vtbl, "StatusBar", Widget_vtbl, sizeof(StatusBar), .render = StatusBar_render);

StatusBar *StatusBar_new(App *app)
{
    StatusBar *sb = DUOP_NEW(StatusBar, StatusBar_vtbl);
    if (!sb) return nullptr;
    Widget_init(&sb->base, app, 102);
    sb->app = (uint64_t)(uintptr_t)app;
    return sb;
}

void StatusBar_set_message(StatusBar *self, const char *msg, int kind, int ttl_ms)
{
    (void)str_copy((char *)self->msg, msg, STATUS_MAX);
    self->msg_kind = (uint32_t)kind;
    self->msg_expire_ms = (uint64_t)(sys_clock_ms() + ttl_ms);
}

static void sb_text(ScreenBuffer *scr, const Widget *w, const char *s, int max) { (void)ScreenBuffer_draw_text(scr, w->x, w->y, s, max); }

/* the message with its kind's mark and colour */
static void sb_message(StatusBar *self, ScreenBuffer *scr, const Theme *t, char *line)
{
    static const char *const pfx[4] = {" • ", " ✓ ", " ! ", " ✗ "};
    uint32_t k = self->msg_kind;
    uint32_t fg = k == MSG_OK ? t->ok_fg : k == MSG_WARN ? t->warn_fg : k == MSG_ERR ? t->err_fg : t->accent;
    ScreenBuffer_set_pen(scr, fg, t->bg, ATTR_BOLD);
    (void)str_copy(line, pfx[k <= MSG_ERR ? k : MSG_INFO], SB_LINE);
    (void)str_cat(line, (const char *)self->msg, SB_LINE);
    sb_text(scr, &self->base, line, self->base.w);
}

/* " ⟳ Copying 45%  ·  ..." on the left, the "details" hint on the right */
static void sb_task(StatusBar *self, ScreenBuffer *scr, const Theme *t, App *app, char *line)
{
    ProgressDialog_format_summary(app->task_snap, line);
    const char *hint = i18n_get()->s[LS_task_sb_hint];
    int hw = utf8_display_width(hint);
    const Widget *w = &self->base;
    ScreenBuffer_set_pen(scr, t->accent, t->bg, ATTR_BOLD);
    sb_text(scr, w, line, w->w - hw - 2);
    ScreenBuffer_set_pen(scr, t->muted, t->bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, w->x + w->w - hw - 1, w->y, hint, hw + 1);
}

/* " -> <target>" of a symlink entry */
static void sb_link_target(DirModel *m, const FileEntry *e, char *line)
{
    char *buf = mem_alloc(PATH_MAX + 512);
    if (!buf) return;
    (void)path_join(buf, m->path, DirModel_entry_name(m, e), PATH_MAX);     /* a path that does not fit reads as "" */
    intptr_t n = os_readlinkat(AT_FDCWD, buf, buf + PATH_MAX, 511);
    if (n > 0) {
        buf[PATH_MAX + n] = 0;
        (void)str_cat(line, " → ", SB_LINE);
        (void)str_cat(line, buf + PATH_MAX, SB_LINE);
    }
    mem_free(buf);
}

/* " <name>  │  <size>  │  <perms>  │  <date>[ → <target>]" */
static void sb_entry_line(DirModel *m, FileEntry *e, char *line)
{
    static const char sep[] = "  │  ";
    char tmp[32];
    DirModel_ensure_entry_stat(m, e);
    line[0] = ' ';
    line[1] = 0;
    (void)str_cat(line, DirModel_entry_name(m, e), SB_LINE);
    (void)str_cat(line, sep, SB_LINE);
    if (e->flags & FE_IS_DIR) (void)str_cat(line, i18n_get()->s[LS_sb_dir_tag], SB_LINE);
    else { (void)format_size(e->size, tmp); (void)str_cat(line, tmp, SB_LINE); }
    (void)str_cat(line, sep, SB_LINE);
    format_perms(e->mode, tmp);
    (void)str_cat(line, tmp, SB_LINE);
    if (e->flags & FE_IS_PARENT) return;
    (void)str_cat(line, sep, SB_LINE);
    format_datetime(e->mtime, tmp);
    (void)str_cat(line, tmp, SB_LINE);
    if (e->flags & FE_IS_LINK) sb_link_target(m, e, line);
}

/* the key hint at the right end, when the bar is wide enough: true when drawn */
static void sb_hint(const Widget *w, ScreenBuffer *scr, const Theme *t)
{
    const char *hint = i18n_get()->s[LS_sb_hint_right];
    int hw = utf8_display_width(hint);
    if (w->w < SB_HINT_MIN_W || w->w - hw - 3 < 20) return;
    ScreenBuffer_set_pen(scr, t->muted, t->bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, w->x + w->w - hw - 1, w->y, hint, hw + 1);
}

/* the filter of a listing without entries, or nothing */
static void sb_filter(const Widget *w, ScreenBuffer *scr, const Theme *t, const DirModel *m, char *line)
{
    if (!m->filter[0]) return;
    ScreenBuffer_set_pen(scr, t->warn_fg, t->bg, ATTR_BOLD);
    (void)str_copy(line, i18n_get()->s[LS_sb_filter_pfx], SB_LINE);
    (void)str_cat(line, m->filter, SB_LINE);
    (void)str_cat(line, i18n_get()->s[LS_sb_filter_sfx], SB_LINE);
    sb_text(scr, w, line, w->w);
}

void StatusBar_render(Widget *widget, void *screen, void *theme)
{
    StatusBar *self = (StatusBar *)widget;
    ScreenBuffer *scr = screen;
    const Theme *t = theme;
    const Widget *w = &self->base;
    char line[SB_LINE];
    ScreenBuffer_set_pen(scr, t->text, t->bg, ATTR_NONE);
    ScreenBuffer_fill_rect(scr, w->x, w->y, w->w, 1, ' ');
    if (self->msg_expire_ms) {
        if ((uint64_t)sys_clock_ms() < self->msg_expire_ms) { sb_message(self, scr, t, line); return; }
        self->msg_expire_ms = 0;
    }
    App *app = (App *)(uintptr_t)self->app;
    if (app->task_active) { sb_task(self, scr, t, app, line); return; }
    FilePane *fp = (FilePane *)(uintptr_t)app->active_pane;
    if (!fp) return;
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    FileEntry *e = DirModel_get_entry(m, fp->cursor);
    if (!e) {
        if (m->filter[0]) { sb_filter(w, scr, t, m, line); return; }
        sb_hint(w, scr, t);
        return;
    }
    sb_entry_line(m, e, line);
    int max = w->w;
    if (w->w >= SB_HINT_MIN_W) {
        int room = w->w - utf8_display_width(i18n_get()->s[LS_sb_hint_right]) - 3;
        if (room >= 20) max = room;
    }
    ScreenBuffer_set_pen(scr, t->text, t->bg, ATTR_NONE);
    sb_text(scr, w, line, max);
    sb_hint(w, scr, t);
}
