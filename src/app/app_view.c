/* src/app/app_view.c - F3 file viewer dispatch (image "Open as" dialog vs direct viewer)
 * and Alt+V preview mode cycle (freestanding C23; replaces src/app/app_view.s,
 * kept as tests/harness/app_view_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_img.h"
#include "duop_ui.h"

void App_open_viewer(App *app, const char *path)
{
    uint8_t head[32];
    size_t n = 0;
    (void)fs_read_file_head(path, head, sizeof head, &n);
    int fmt = img_detect(head, n, path);
    if (fmt) app->active_dialog = (uint64_t)(uintptr_t)ViewAsDialog_new(app, path, fmt);
    else app->active_dialog = (uint64_t)(uintptr_t)ViewerDialog_new(app, path);
    app->need_redraw = 1;
}

void App_view_as_done(App *app, ViewAsDialog *dlg)
{
    ViewerDialog *v = ViewerDialog_new(app, (const char *)dlg->path);
    if (!v) return;
    ViewerDialog_set_mode(v, (int)dlg->choice);
    app->active_dialog = (uint64_t)(uintptr_t)v;
    app->need_redraw = 1;
}

int App_cmd_view_mode(App *app)
{
    if (app->right_mode == RIGHT_MODE_PREVIEW)
        PreviewPane_cycle_mode((PreviewPane *)(uintptr_t)app->preview_pane);
    return 1;
}
