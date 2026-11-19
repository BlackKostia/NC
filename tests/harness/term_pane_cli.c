/* Freestanding differential harness for src/ui/term_pane.c versus frozen x86_64 asm
 * (tests/harness/term_pane_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static FilePane g_fp;
static DirModel g_dm;
static int g_fail_alloc;
static int g_spawn_rc;
static int g_spawn_fd = 7;
static const char *g_read_chunks[8];
static int g_read_idx, g_read_cnt;

void App_set_status(App *app, const char *msg, int kind)
{
    sc_put("call App_set_status "); sc_num(app == &g_app);
    sc_put(" k="); sc_num(kind); sc_put(" |"); sc_esc(msg ? msg : ""); sc_put("|\n");
}

const char *fake_fs_errno_message(int neg_errno);
const char *fake_fs_errno_message(int neg_errno)
{
    sc_put("call fs_errno_message "); sc_num(neg_errno); sc_put("\n");
    return "Out of memory";
}

void fake_input_set_aux_fd(int slot, int fd);
void fake_input_set_aux_fd(int slot, int fd)
{
    sc_put("call input_set_aux_fd slot="); sc_num(slot); sc_put(" fd="); sc_num(fd); sc_put("\n");
}

int fake_os_pty_spawn(int *out_fd, int *out_pid, const char *cwd, char **envp, int cols, int rows);
int fake_os_pty_spawn(int *out_fd, int *out_pid, const char *cwd, char **envp, int cols, int rows)
{
    (void)envp;
    sc_put("call os_pty_spawn cwd="); sc_esc(cwd); sc_put(" sz="); sc_num(cols); sc_put("x"); sc_num(rows); sc_put("\n");
    if (g_spawn_rc != 0) return g_spawn_rc;
    *out_fd = g_spawn_fd;
    *out_pid = 4321;
    return 0;
}

intptr_t fake_os_pty_read(int fd, void *buf, size_t len);
intptr_t fake_os_pty_read(int fd, void *buf, size_t len)
{
    if (g_read_idx >= g_read_cnt) return 0;
    const char *src = g_read_chunks[g_read_idx++];
    size_t n = str_len(src);
    if (n > len) n = len;
    mem_copy(buf, src, n);
    sc_put("call os_pty_read fd="); sc_num(fd); sc_put(" n="); sc_num((int64_t)n); sc_put("\n");
    return (intptr_t)n;
}

intptr_t fake_os_pty_write(int fd, const void *buf, size_t len);
intptr_t fake_os_pty_write(int fd, const void *buf, size_t len)
{
    ui_log_call_bytes("os_pty_write", fd, buf, len);
    return (intptr_t)len;
}

void *fake_mem_alloc(uint64_t size);
void *fake_mem_alloc(uint64_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return mem_alloc(size);
}

#define fs_errno_message fake_fs_errno_message
#define input_set_aux_fd fake_input_set_aux_fd
#define os_pty_spawn fake_os_pty_spawn
#define os_pty_read fake_os_pty_read
#define os_pty_write fake_os_pty_write
#define mem_alloc fake_mem_alloc
#include TP_SRC
#undef mem_alloc
#undef os_pty_write
#undef os_pty_read
#undef os_pty_spawn
#undef input_set_aux_fd
#undef fs_errno_message

#ifdef __x86_64__
extern int ref_term_height(int main_h);
extern void ref_term_toggle(App *app);
extern void ref_term_poll_read(App *app);
extern void ref_term_render(App *app, ScreenBuffer *scr, const Theme *th);
extern int32_t ref_g_term_visible;
extern int32_t ref_g_term_inited;
extern int32_t ref_g_term_fd;
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define VIS (g_ref ? ref_g_term_visible : g_term_visible)
#define INI (g_ref ? ref_g_term_inited : g_term_inited)
#define TFD (g_ref ? ref_g_term_fd : g_term_fd)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define VIS g_term_visible
#define INI g_term_inited
#define TFD g_term_fd
#endif

static bool g_ref;

static void dump_st(const char *tag)
{
    sc_put(tag);
    sc_put(" vis="); sc_num(VIS); sc_put(" ini="); sc_num(INI);
    sc_put(" fd="); sc_num(TFD); sc_put(" rd="); sc_num(g_app.need_redraw);
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(60, 24);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    mem_zero(&g_fp, sizeof g_fp);
    mem_zero(&g_dm, sizeof g_dm);
    g_fp.model = (uint64_t)(uintptr_t)&g_dm;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_fp;
    g_app.theme = (uintptr_t)theme;
    g_app.term_w = 60;
    g_app.term_h = 24;
    (void)str_copy(g_dm.path, "/tmp/work", sizeof g_dm.path);

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'E': {
            g_fail_alloc = (int)ui_parse_num(&a);
            g_spawn_rc = (int)ui_parse_num(&a);
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            break;
        }
        case 'C': {
            while (*a == ' ') a++;
            (void)str_copy(g_dm.path, a, sizeof g_dm.path);
            break;
        }
        case 'H': {
            int mh = (int)ui_parse_num(&a);
            sc_put("H "); sc_num(mh); sc_put(" -> "); sc_num(CALL(term_height, mh)); sc_put("\n");
            break;
        }
        case 'T': {
            g_app.need_redraw = 0;
            CALL(term_toggle, &g_app);
            dump_st("T");
            break;
        }
        case 'P': {
            int pat = (int)ui_parse_num(&a);
            g_read_idx = 0;
            g_read_cnt = 1;
            if (pat == 0) {
                g_read_chunks[0] = "hi\tworld\b!\r\n\x1b[31mCSI\x1b[0m \x1b]0;title\x07OSC \x1bXok\n";
            } else if (pat == 1) {
                /* wrap at term_w-2 + backspace at 0 + non-printable control */
                g_read_chunks[0] = "\b\x01" "012345678901234567890123456789012345678901234567890123456789XY";
            } else {
                /* trigger 50 newlines to test term_scroll_up (TERM_ROWS=48) */
                g_read_chunks[0] = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
                                   "21\n22\n23\n24\n25\n26\n27\n28\n29\n30\n31\n32\n33\n34\n35\n36\n37\n38\n39\n40\n"
                                   "41\n42\n43\n44\n45\n46\n47\n48\n49\n50\nPrompt> ";
            }
            g_app.need_redraw = 0;
            CALL(term_poll_read, &g_app);
            dump_st("P");
            break;
        }
        case 'R': {
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALL(term_render, &g_app, scr, theme);
            int th = CALL(term_height, (int)g_app.term_h - 3);
            if (th > 0) ui_dump(scr, (int)g_app.term_h - 2 - th, th);
            else sc_put("R hidden\n");
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
