/* src/ui/bulk_rename.c - Bulk Rename Dialog (templates {n}/{name}/{ext}, find/replace, live preview)
 * (freestanding C23; replaces src/ui/bulk_rename{,_ui}.s, kept as
 * tests/harness/bulk_rename{,_ui}_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void BulkRenameDialog_dtor(Object *self);
static void BulkRenameDialog_layout(Widget *self, int x, int y, int w, int h);
static void BulkRenameDialog_render(Widget *self, void *screen, void *theme);
static int BulkRenameDialog_on_key(Widget *self, void *event);

DIALOG_VTBL(BulkRenameDialog_vtbl, "BulkRenameDialog", Dialog_vtbl, sizeof(BulkRenameDialog),
            .base.base.dtor = BulkRenameDialog_dtor,
            .base.layout = BulkRenameDialog_layout,
            .base.render = BulkRenameDialog_render,
            .base.on_key = BulkRenameDialog_on_key);

static void BulkRenameDialog_dtor(Object *self)
{
    BulkRenameDialog *d = (BulkRenameDialog *)self;
    if (d->names) mem_free((void *)(uintptr_t)d->names);
    Dialog_dtor(&d->base.base);
}

static int br_collect_names(BulkRenameDialog *d, FilePane *pane)
{
    const DirModel *dm = (const DirModel *)(uintptr_t)pane->model;
    const uint32_t *order = (const uint32_t *)(uintptr_t)dm->order;
    const FileEntry *entries = (const FileEntry *)(uintptr_t)dm->entries;
    int cnt = (int)dm->count;
    int marked = 0;

    for (int i = 0; i < cnt; i++) {
        uint32_t fl = entries[order[i]].flags;
        if (!(fl & FE_IS_PARENT) && (fl & FE_SELECTED)) marked++;
    }

    if (marked == 0) {
        const FileEntry *e = FilePane_get_selected_entry(pane);
        if (!e || (e->flags & FE_IS_PARENT)) return 0;
        char *buf = mem_alloc(256);
        if (!buf) return 0;
        d->names = (uintptr_t)buf;
        d->count = 1;
        (void)str_copy(buf, DirModel_entry_name(dm, e), 256);
        return 1;
    }

    char *buf = mem_alloc((size_t)marked * 256);
    if (!buf) return 0;
    d->names = (uintptr_t)buf;
    d->count = (uint32_t)marked;
    int out = 0;
    for (int i = 0; i < cnt && out < marked; i++) {
        const FileEntry *e = &entries[order[i]];
        if ((e->flags & FE_IS_PARENT) || !(e->flags & FE_SELECTED)) continue;
        (void)str_copy(buf + (size_t)out * 256, DirModel_entry_name(dm, e), 256);
        out++;
    }
    return marked;
}

BulkRenameDialog *BulkRenameDialog_new(App *app, FilePane *pane)
{
    BulkRenameDialog *d = DUOP_NEW(BulkRenameDialog, BulkRenameDialog_vtbl);
    if (!d) return nullptr;

    d->pane = (uintptr_t)pane;
    if (br_collect_names(d, pane) == 0) {
        mem_free(d);
        return nullptr;
    }

    Dialog_init(&d->base, app, i18n_get()->s[LS_br_title], 0);
    BulkRenameDialog_layout(&d->base.base, 0, 0, (int)app->term_w, (int)app->term_h);
    return d;
}

static void BulkRenameDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 4;
    if (dw > 68) dw = 68;
    if (dw < 36) dw = 36;

    int dh = h - 4;
    if (dh > 20) dh = 20;
    if (dh < 12) dh = 12;

    Widget_layout(self, (w - dw) >> 1, (h - dh) >> 1, dw, dh);
    const LangStrings *ls = i18n_get();
    dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);
}

static int br_match_tok(const char *s, const char *tok)
{
    int i = 0;
    while (tok[i]) {
        if (s[i] != tok[i]) return 0;
        i++;
    }
    return i;
}

static void br_append(char *out, int *pos, int max, const char *s)
{
    while (*s && *pos < max) out[(*pos)++] = *s++;
}

static void br_expand_tmpl(const BulkRenameDialog *d, int idx, const char *old, char *out, int cap)
{
    int max = cap - 1;
    int pos = 0;
    int dot = (int)str_len(old) - 1;
    while (dot >= 0 && old[dot] != '.') dot--;

    const char *p = (const char *)d->tmpl;
    while (*p) {
        if (*p == '{') {
            int n;
            if ((n = br_match_tok(p, "{n}")) > 0) {
                char num[24];
                (void)u64_to_dec((uint64_t)(idx + 1), num);
                br_append(out, &pos, max, num);
                p += n;
                continue;
            }
            if ((n = br_match_tok(p, "{name}")) > 0) {
                for (int i = 0; (dot < 0 || i < dot) && old[i] && pos < max; i++)
                    out[pos++] = old[i];
                p += n;
                continue;
            }
            if ((n = br_match_tok(p, "{ext}")) > 0) {
                if (dot >= 0) br_append(out, &pos, max, old + dot + 1);
                p += n;
                continue;
            }
        }
        if (pos < max) out[pos++] = *p;
        p++;
    }
    out[pos] = '\0';
}

static void br_compute_name(const BulkRenameDialog *d, int idx, const char *old, char *out, int cap)
{
    if ((int)d->tlen > 0)
        br_expand_tmpl(d, idx, old, out, cap);
    else
        (void)str_copy(out, old, (size_t)cap);

    if (d->flen > 0) {
        char tmp[256];
        int len = 0;
        const char *p = out;
        while (*p) {
            int n = br_match_tok(p, (const char *)d->find);
            if (n > 0) {
                p += n;
                br_append(tmp, &len, 255, (const char *)d->repl);
            } else {
                if (len >= 255) break;
                tmp[len++] = *p++;
            }
        }
        tmp[len] = '\0';
        (void)str_copy(out, tmp, (size_t)cap);
    }
}

static void br_draw_field(const BulkRenameDialog *d, ScreenBuffer *scr, const Theme *th, int field_idx)
{
    const LangStrings *ls = i18n_get();
    const char *lbl = field_idx == 0 ? ls->s[LS_br_tmpl]
                    : field_idx == 1 ? ls->s[LS_br_find]
                                     : ls->s[LS_br_repl];
    const char *val = (const char *)(field_idx == 0 ? d->tmpl
                                   : field_idx == 1 ? d->find
                                                    : d->repl);
    int ry = d->base.base.y + 2 + field_idx;
    int fw = d->base.base.w - 16;

    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 2, ry, lbl, 11);

    if ((int)d->focus == field_idx)
        ScreenBuffer_set_pen(scr, th->text, th->surface_alt, ATTR_BOLD);
    else
        ScreenBuffer_set_pen(scr, th->text, th->surface, ATTR_NONE);

    ScreenBuffer_draw_hline(scr, d->base.base.x + 14, ry, fw, ' ');
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 14, ry, val, fw);
}

static void BulkRenameDialog_render(Widget *self, void *screen, void *theme)
{
    BulkRenameDialog *d = (BulkRenameDialog *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(&d->base, scr, th, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);
    br_draw_field(d, scr, th, 0);
    br_draw_field(d, scr, th, 1);
    br_draw_field(d, scr, th, 2);

    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    int max_rows = d->base.base.h - 9;
    const char *names = (const char *)(uintptr_t)d->names;
    char new_name[256], line[256];
    for (int i = 0; i < max_rows && i < (int)d->count; i++) {
        const char *old = names + (size_t)i * 256;
        br_compute_name(d, i, old, new_name, sizeof new_name);
        (void)str_copy(line, old, sizeof line);
        (void)str_cat(line, " -> ", sizeof line);
        (void)str_cat(line, new_name, sizeof line);
        (void)ScreenBuffer_draw_text(scr, d->base.base.x + 2, d->base.base.y + 6 + i,
                                     line, d->base.base.w - 4);
    }
}

static void br_apply(BulkRenameDialog *d)
{
    FilePane *pane = (FilePane *)(uintptr_t)d->pane;
    DirModel *dm = (DirModel *)(uintptr_t)pane->model;
    intptr_t dir_fd = os_openat(AT_FDCWD, (const char *)dm->path,
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (dir_fd >= 0) {
        const char *names = (const char *)(uintptr_t)d->names;
        char new_name[256];
        for (int i = 0; i < (int)d->count; i++) {
            const char *old = names + (size_t)i * 256;
            br_compute_name(d, i, old, new_name, sizeof new_name);
            if (new_name[0] == '\0' || str_cmp(new_name, old) == 0) continue;
            (void)os_renameat2((int)dir_fd, old, (int)dir_fd, new_name, RENAME_NOREPLACE);
        }
        (void)os_close((int)dir_fd);
        (void)DirModel_reload(dm);
    }
    Dialog_on_confirm(&d->base);
}

static int BulkRenameDialog_on_key(Widget *self, void *event)
{
    BulkRenameDialog *d = (BulkRenameDialog *)self;
    App *app = (App *)(uintptr_t)d->base.app;
    uint32_t key = ((const Event *)event)->key;

    if (key == KEY_ESC) { Dialog_on_cancel(&d->base); return 1; }
    if (key == KEY_TAB) {
        d->focus = (d->focus + 1) % 5;
        app->need_redraw = 1;
        return 1;
    }
    if (key == KEY_ENTER) {
        if (d->focus == 4) { Dialog_on_cancel(&d->base); return 1; }
        br_apply(d);
        return 1;
    }
    if (d->focus >= 3) return 0;

    uint8_t *buf = d->focus == 0 ? d->tmpl : (d->focus == 1 ? d->find : d->repl);
    uint32_t *len_p = d->focus == 0 ? &d->tlen : (d->focus == 1 ? &d->flen : &d->rlen);
    if (key == KEY_BACKSPACE) {
        if (*len_p > 0) { (*len_p)--; buf[*len_p] = '\0'; }
        app->need_redraw = 1;
        return 1;
    }
    if (key < 32 || key > 126) return 0;
    if (*len_p < 126) {
        buf[(*len_p)++] = (uint8_t)key;
        buf[*len_p] = '\0';
    }
    app->need_redraw = 1;
    return 1;
}
