/* src/ui/file_pane_tabs.c - FilePane tabs and navigation history helpers
 * (freestanding C23; replaces src/ui/file_pane_tabs.s,
 * kept as tests/harness/file_pane_tabs_reference.s). */
#include "duop_classes.h"
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_ui.h"

NavTab *fp_get_active_tab(FilePane *self)
{
    NavTab *tabs = (NavTab *)(uintptr_t)self->tabs;
    if (!tabs) return nullptr;
    int idx = (int32_t)self->active_tab;
    if (idx < 0 || idx >= (int32_t)self->tab_count) return nullptr;
    return &tabs[idx];
}

static void fp_save_tab(FilePane *self)
{
    NavTab *t = fp_get_active_tab(self);
    if (!t) return;
    DirModel *m = (DirModel *)(uintptr_t)self->model;
    t->cursor = (int32_t)self->cursor;
    t->scroll = (int32_t)self->scroll;
    t->sort_mode = m->sort_mode;
    t->sort_desc = m->sort_desc;
    t->show_hidden = m->show_hidden;
    (void)str_copy(t->path, m->path, PATH_MAX);
}

intptr_t FilePane_nav_to(FilePane *self, const char *path)
{
    DirModel *m = (DirModel *)(uintptr_t)self->model;
    intptr_t rc = DirModel_chdir(m, path);
    if (rc < 0) return rc;
    if (m->du_mode) dir_du_populate(m);
    self->cursor = 0;
    self->scroll = 0;
    FilePane_ensure_visible(self);
    NavTab *t = fp_get_active_tab(self);
    if (t) nav_hist_push(t, m->path);
    nav_frecency_record(m->path);
    return 0;
}

static int fp_hist_step(FilePane *self, const char *(*step_fn)(NavTab *))
{
    NavTab *t = fp_get_active_tab(self);
    if (!t) return 0;
    const char *p = step_fn(t);
    if (!p) return 0;
    DirModel *m = (DirModel *)(uintptr_t)self->model;
    if (DirModel_chdir(m, p) < 0) return 0;
    self->cursor = 0;
    self->scroll = 0;
    FilePane_ensure_visible(self);
    return 1;
}

int FilePane_hist_back(FilePane *self) { return fp_hist_step(self, nav_hist_back); }
int FilePane_hist_fwd(FilePane *self)  { return fp_hist_step(self, nav_hist_fwd); }

int FilePane_tab_new(FilePane *self)
{
    if ((int32_t)self->tab_count >= NAV_TAB_MAX || !self->tabs) return 0;
    fp_save_tab(self);
    int idx = (int32_t)self->tab_count;
    NavTab *t = &((NavTab *)(uintptr_t)self->tabs)[idx];
    mem_zero(t, sizeof *t);
    DirModel *m = (DirModel *)(uintptr_t)self->model;
    (void)str_copy(t->path, m->path, PATH_MAX);
    nav_hist_push(t, m->path);
    self->active_tab = (uint32_t)idx;
    self->tab_count++;
    return 1;
}

int FilePane_tab_switch(FilePane *self, int idx)
{
    if (idx < 0 || idx >= (int32_t)self->tab_count) return 0;
    if (idx == (int32_t)self->active_tab) return 1;
    fp_save_tab(self);
    self->active_tab = (uint32_t)idx;
    NavTab *t = fp_get_active_tab(self);
    if (t) {
        DirModel *m = (DirModel *)(uintptr_t)self->model;
        m->sort_mode = t->sort_mode;
        m->sort_desc = t->sort_desc;
        m->show_hidden = t->show_hidden;
        (void)DirModel_chdir(m, t->path);
        self->cursor = (uint32_t)t->cursor;
        self->scroll = (uint32_t)t->scroll;
        FilePane_ensure_visible(self);
    }
    return 1;
}

int FilePane_tab_close(FilePane *self, int idx)
{
    if ((int32_t)self->tab_count <= 1) return 0;
    if (idx < 0) idx = (int32_t)self->active_tab;
    if (idx >= (int32_t)self->tab_count) return 0;
    NavTab *tabs = (NavTab *)(uintptr_t)self->tabs;
    if (!tabs) return 0;

    for (int i = 0; i < tabs[idx].hist_len; i++) {
        if (tabs[idx].hist[i]) mem_free(tabs[idx].hist[i]);
    }
    int last = (int32_t)self->tab_count - 1;
    for (int k = idx; k < last; k++) {
        mem_copy(&tabs[k], &tabs[k + 1], sizeof(NavTab));
    }
    self->tab_count--;

    int act = (int32_t)self->active_tab;
    if (act > idx) {
        self->active_tab--;
    } else if (act == idx) {
        if (act >= (int32_t)self->tab_count) self->active_tab = self->tab_count - 1;
        NavTab *t = fp_get_active_tab(self);
        if (t) {
            DirModel *m = (DirModel *)(uintptr_t)self->model;
            (void)DirModel_chdir(m, t->path);
            self->cursor = (uint32_t)t->cursor;
            self->scroll = (uint32_t)t->scroll;
            FilePane_ensure_visible(self);
        }
    }
    return 1;
}
