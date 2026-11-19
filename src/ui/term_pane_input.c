/* src/ui/term_pane_input.c - embedded PTY pane key dispatch and shutdown (freestanding C23; replaces
 * src/ui/term_pane_input.s, kept as tests/harness/term_pane_input_reference.s). */
#include "duop_classes.h"
#include "duop_tui.h"
#include "duop_ui.h"

extern int32_t g_term_visible;
extern int32_t g_term_inited;
extern int32_t g_term_fd;
void term_toggle(App *app);

int term_on_key(void *app, void *evt)
{
    if (!g_term_visible) return 0;
    const Event *e = evt;
    if (e->mods == MOD_CTRL && e->key == '`') {
        term_toggle(app);
        return 2;
    }
    if (g_term_fd < 0) return 1;
    char buf[16];
    int n = term_key_encode(e, buf);
    if (n < 0) return 0;
    if (n == 0) return 1;
    (void)os_pty_write(g_term_fd, buf, (size_t)n);
    return 1;
}

void term_shutdown(void)
{
    if (!g_term_inited || g_term_fd < 0) return;
    os_pty_close(g_term_fd);
    g_term_fd = -1;
}
