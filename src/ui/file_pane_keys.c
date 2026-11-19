/* src/ui/file_pane_keys.c - FilePane keyboard navigation and scrollbar scrubbing
 * (freestanding C23; replaces src/ui/file_pane_keys.s,
 * kept as tests/harness/file_pane_keys_reference.s). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"

int FilePane_on_key(Widget *self, void *event)
{
    FilePane *fp = (FilePane *)self;
    const Event *ev = (const Event *)event;
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    App *app = (App *)(uintptr_t)fp->app;
    int key = ev->lat;

    if (ev->mods & MOD_CTRL) {
        if (key == 'a') { DirModel_select_all_toggle(m); goto sync; }
        return 0;
    }

    switch (key) {
    case KEY_UP: case 'k': fp->cursor--; break;
    case KEY_DOWN: case 'j': fp->cursor++; break;
    case KEY_PGUP: fp->cursor -= (uint32_t)get_list_h(fp); break;
    case KEY_PGDN: fp->cursor += (uint32_t)get_list_h(fp); break;
    case KEY_HOME: case 'g': fp->cursor = 0; break;
    case KEY_END: case 'G': fp->cursor = (uint32_t)((int32_t)m->count - 1); break;
    case ' ': case KEY_INSERT: DirModel_toggle_select(m, (int32_t)fp->cursor); fp->cursor++; break;
    case '*': DirModel_select_all_toggle(m); break;
    case KEY_ENTER: App_open_selected_entry(app, fp); goto handled;
    case KEY_BACKSPACE: FilePane_enter_parent(fp); App_sync_preview(app); goto handled;
    case '~': {
        const char *home = env_getenv((char **)(uintptr_t)app->envp, "HOME");
        if (!home) goto handled;
        if (DirModel_chdir(m, home) >= 0) {
            if (m->du_mode) dir_du_populate(m);
            fp->cursor = 0;
            fp->scroll = 0;
        }
        break;
    }
    default: return 0;
    }

sync:
    FilePane_ensure_visible(fp);
    App_sync_preview(app);
handled:
    app->need_redraw = 1;
    return 1;
}

void scrub_scrollbar(FilePane *self, int my)
{
    int rel = my - self->base.y - 3;
    if (rel < 0) rel = 0;
    int lh = get_list_h(self);
    if (rel >= lh) rel = lh - 1;
    DirModel *m = (DirModel *)(uintptr_t)self->model;
    int max_scroll = (int32_t)m->count - lh;
    if (max_scroll <= 0 || lh < 2) {
        self->scroll = 0;
        return;
    }
    self->scroll = ((uint32_t)rel * (uint32_t)max_scroll) / (uint32_t)(lh - 1);
}
