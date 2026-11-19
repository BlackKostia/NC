/* src/ui/term_pane.c - Embedded bottom PTY terminal pane (Ctrl+`): VT buffer, ANSI escape
 * stripper, PTY spawn / CWD sync / non-blocking poll read, and bordered pane rendering
 * (freestanding C23; replaces src/ui/term_pane.s, kept as tests/harness/term_pane_reference.s). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define TERM_COLS 160
#define TERM_ROWS 48
#define TERM_BUF_SZ (TERM_COLS * TERM_ROWS)

int32_t g_term_visible;
int32_t g_term_inited;
int32_t g_term_fd;

static int32_t g_term_pid;
static int32_t g_term_cx;
static int32_t g_term_cy;
static int32_t g_term_esc;
static int32_t g_term_vis_w;
static uint8_t *g_term_buf;
static char g_term_last_cwd[4096];

int term_height(int main_h)
{
    if (!g_term_visible || main_h < 9) return 0;
    int h = main_h / 3;
    return h >= 6 ? h : 6;
}

static void term_scroll_up(void)
{
    if (!g_term_buf) return;
    mem_copy(g_term_buf, g_term_buf + TERM_COLS, TERM_COLS * (TERM_ROWS - 1));
    os_mem_set_fast(g_term_buf + TERM_COLS * (TERM_ROWS - 1), ' ', TERM_COLS);
}

static void term_lf(void)
{
    g_term_cx = 0;
    g_term_cy++;
    if (g_term_cy >= TERM_ROWS) {
        term_scroll_up();
        g_term_cy = TERM_ROWS - 1;
    }
}

static void term_put_byte(uint8_t b)
{
    if (g_term_esc == 1) {
        if (b == '[') g_term_esc = 2;
        else if (b == ']') g_term_esc = 3;
        else g_term_esc = 0;
        return;
    }
    if (g_term_esc == 2) {
        if (b >= 0x40 && b <= 0x7E) g_term_esc = 0;
        return;
    }
    if (g_term_esc == 3) {
        if (b == 7 || b == '\n') g_term_esc = 0;
        return;
    }
    if (b == 0x1B) { g_term_esc = 1; return; }
    if (b == '\r') { g_term_cx = 0; return; }
    if (b == '\n') { term_lf(); return; }
    if (b == '\b' || b == 0x7F) {
        if (g_term_cx > 0) g_term_cx--;
        return;
    }
    if (b == '\t') {
        g_term_cx = (g_term_cx + 8) & ~7;
        if (g_term_cx >= TERM_COLS) g_term_cx = TERM_COLS - 1;
        return;
    }
    if (b < 0x20 || !g_term_buf) return;
    int idx = g_term_cy * TERM_COLS + g_term_cx;
    if (idx < 0 || idx >= TERM_BUF_SZ) return;
    g_term_buf[idx] = b;
    g_term_cx++;
    int w = g_term_vis_w;
    if (w < 10) w = 80;
    if (w > TERM_COLS) w = TERM_COLS;
    if (g_term_cx >= w) { g_term_cx = 0; term_lf(); }
}

static void term_sync_cwd(App *app)
{
    if (g_term_fd < 0) return;
    FilePane *fp = (FilePane *)(uintptr_t)app->active_pane;
    if (!fp) return;
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    if (!m || !m->path[0]) return;
    if (str_cmp(m->path, g_term_last_cwd) == 0) return;
    (void)str_copy(g_term_last_cwd, m->path, sizeof g_term_last_cwd);

    char *cmd = mem_alloc(4136);
    if (!cmd) return;
    cmd[0] = 'c'; cmd[1] = 'd'; cmd[2] = ' '; cmd[3] = '\'';
    size_t n = 4;
    for (size_t i = 0; m->path[i] && n < 4120; i++) {
        char ch = m->path[i];
        if (ch == '\'') {
            cmd[n++] = '\''; cmd[n++] = '\\'; cmd[n++] = '\''; cmd[n++] = '\'';
        } else {
            cmd[n++] = ch;
        }
    }
    cmd[n++] = '\'';
    cmd[n++] = '\r';
    (void)os_pty_write(g_term_fd, cmd, n);
    mem_free(cmd);
}

void term_toggle(App *app)
{
    g_term_visible ^= 1;
    if (!g_term_visible) {
        app->need_redraw = 1;
        return;
    }
    g_term_vis_w = (int32_t)app->term_w - 2;
    if (g_term_inited) {
        term_sync_cwd(app);
        app->need_redraw = 1;
        return;
    }
    g_term_inited = 1;
    g_term_fd = -1;
    g_term_buf = mem_alloc(TERM_BUF_SZ);
    if (!g_term_buf) {
        g_term_visible = 0;
        g_term_inited = 0;
        App_set_status(app, fs_errno_message(-ENOMEM), MSG_ERR);
        app->need_redraw = 1;
        return;
    }
    os_mem_set_fast(g_term_buf, ' ', TERM_BUF_SZ);

    int rows = term_height((int)app->term_h - 3) - 2;
    if (rows < 1) rows = 1;
    int cols = (int)app->term_w - 2;
    if (cols < 1) cols = 1;
    FilePane *fp = (FilePane *)(uintptr_t)app->active_pane;
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    if (os_pty_spawn(&g_term_fd, &g_term_pid, m->path, (char **)(uintptr_t)app->envp, cols, rows) == 0) {
        (void)str_copy(g_term_last_cwd, m->path, sizeof g_term_last_cwd);
        input_set_aux_fd(3, g_term_fd);
    }
    app->need_redraw = 1;
}

void term_poll_read(App *app)
{
    if (!g_term_inited || g_term_fd < 0) return;
    uint8_t buf[1024];
    for (;;) {
        intptr_t n = os_pty_read(g_term_fd, buf, sizeof buf);
        if (n <= 0) break;
        for (intptr_t i = 0; i < n; i++) term_put_byte(buf[i]);
        app->need_redraw = 1;
    }
}

static void term_draw_cursor(ScreenBuffer *scr, const Theme *theme, int y0, int start_row,
                             int inner_h, int max_x)
{
    int rel = g_term_cy - start_row;
    if (rel < 0 || rel >= inner_h || !g_term_buf) return;
    const uint8_t *row = g_term_buf + g_term_cy * TERM_COLS;
    char prefix[TERM_COLS + 1];
    mem_copy(prefix, row, (size_t)g_term_cx);
    prefix[g_term_cx] = 0;
    int col = utf8_display_width(prefix) + 1;
    if (col >= max_x) return;
    uint8_t ch = row[g_term_cx];
    uint32_t cp = (ch >= 0x21 && ch < 0x7F) ? (uint32_t)ch : ' ';
    ScreenBuffer_set_cell(scr, col, y0 + rel + 1, cp, theme->surface, theme->text);
}

void term_render(App *app, ScreenBuffer *scr, const Theme *theme)
{
    if (!g_term_visible || (int)app->term_w < 4) return;
    int th = term_height((int)app->term_h - 3);
    if (th <= 0) return;
    int y0 = (int)app->term_h - 2 - th;

    ScreenBuffer_set_pen(scr, theme->text, theme->surface, ATTR_NONE);
    ScreenBuffer_fill_rect(scr, 0, y0, (int)app->term_w, th, ' ');
    ScreenBuffer_set_pen(scr, theme->border_active, theme->surface, ATTR_NONE);
    ScreenBuffer_draw_box(scr, 0, y0, (int)app->term_w, th, 1);
    (void)ScreenBuffer_draw_text(scr, 2, y0, i18n_get()->s[LS_term_title], 20);
    ScreenBuffer_set_pen(scr, theme->text, theme->surface, ATTR_NONE);

    int inner_h = th - 2;
    int start_row = g_term_cy + 1 - inner_h;
    if (start_row < 0) start_row = 0;
    if (!g_term_buf) return;

    int copy_w = (int)app->term_w - 2;
    if (copy_w > TERM_COLS) copy_w = TERM_COLS;
    char line[TERM_COLS + 1];
    for (int i = 0; i < inner_h && start_row + i < TERM_ROWS; i++) {
        mem_copy(line, g_term_buf + (start_row + i) * TERM_COLS, (size_t)copy_w);
        line[copy_w] = 0;
        (void)ScreenBuffer_draw_text(scr, 1, y0 + i + 1, line, (int)app->term_w - 2);
    }
    term_draw_cursor(scr, theme, y0, start_row, inner_h, (int)app->term_w - 1);
}
