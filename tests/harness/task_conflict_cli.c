/* Freestanding harness: the frozen asm conflict handling (task_conflict_reference.s, x86_64, ref_ prefix) or src/fs/task_conflict.c
 * (compiled into this unit, path in TCF_SRC), one implementation per process. This process plays the worker; a forked child plays
 * the UI through fs_task_check_conflict / fs_task_reply_conflict of the same implementation and reports what it saw through a pipe.
 * argv = <ref|c> <base dir>; "@" stands for the base dir. Script on stdin:
 *   W <0|1>          UI process / background worker (g_fs_progress)
 *   A <answer>...    a UI child that answers the next conflicts in turn: o s r (overwrite / skip / rename), O S R (... for all),
 *                    c (no answer: the worker's cancel flag is set instead)
 *   E <dst> <src>    fo_resolve_eexist_open(base dir, dst, stat(src)): fd (data written, closed), used flag, name, g_copy_had_skip
 *   M <src> <dst>    fo_move_check_conflict;   Q <dst> <src_sz> <dst_sz>  fs_task_resolve_conflict directly */
#include "script_cli.h"
#include "duop_task.h"
#include "duop_pal.h"

TaskShared *g_fs_progress, *g_task_shm;
int g_task_parent_pid;

#include TCF_SRC

#ifdef __x86_64__
extern FoOpenResult ref_fo_resolve_eexist_open(int, const char *, const FileStat *, char *);
extern intptr_t ref_fo_move_check_conflict(const char *, const char *, char *);
extern intptr_t ref_fs_task_resolve_conflict(int, const char *, uint64_t, uint64_t, char *);
extern int ref_fs_task_check_conflict(char *, uint64_t *, uint64_t *);
extern void ref_fs_task_reply_conflict(int, int);
extern int ref_g_copy_had_skip;
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define SKIPFLAG (*(g_ref ? &ref_g_copy_had_skip : &g_copy_had_skip))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define SKIPFLAG g_copy_had_skip
#endif

static bool g_ref;
static char g_base[PATH_MAX], g_p1[PATH_MAX], g_p2[PATH_MAX], g_out[PATH_MAX];
static TaskShared *g_page;
static int g_ui_pid, g_ui_fd = -1, g_basefd;

static const char *at(const char *p, char *buf)
{
    if (p[0] != '@') return p;
    size_t n = str_copy(buf, g_base, PATH_MAX);
    (void)str_copy(buf + n, p + 1, PATH_MAX - n);
    return buf;
}

static int sc_split(char *line, char **f, int max)
{
    int n = 0;
    while (*line && n < max) {
        while (*line == ' ') *line++ = 0;
        if (!*line) break;
        f[n++] = line;
        while (*line && *line != ' ') line++;
    }
    return n;
}

static int64_t num(const char *s) { int64_t v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0'); return v; }


[[noreturn]] static void ui_child(char **ans, int n, int wfd)
{
    g_task_shm = g_page;
    for (int i = 0; i < n;) {
        char name[TASK_NAME_MAX + 8];
        uint64_t ss = 0, ds = 0;
        if (!CALL(fs_task_check_conflict, name, &ss, &ds)) { (void)os_poll_in(-1, 2); continue; }
        char line[400] = "  seen ";
        size_t k = 7;
        k += str_copy(line + k, name, 260);
        line[k++] = ' ';
        k += u64_to_dec(ss, line + k);
        line[k++] = '/';
        k += u64_to_dec(ds, line + k);
        line[k++] = '\n';
        (void)sys_write_all(wfd, line, k);
        char a = ans[i++][0];
        if (a == 'c') { g_page->cancel = 1; continue; }
        int act = (a | 32) == 'o' ? 1 : (a | 32) == 's' ? 2 : 3;
        CALL(fs_task_reply_conflict, act, a >= 'A' && a <= 'Z');
    }
    os_exit(0);
}

static void drain_ui(void)
{
    static char buf[4096];
    if (g_ui_fd < 0) return;
    intptr_t r;
    while ((r = os_read(g_ui_fd, buf, sizeof buf - 1)) > 0) { buf[r] = 0; sc_put(buf); }
}

static void stop_ui(void)
{
    if (!g_ui_pid) return;
    (void)os_kill(g_ui_pid, SIGKILL);
    int st;
    while (os_wait4(g_ui_pid, &st, 0, nullptr) == -EINTR) {}
    drain_ui();
    (void)os_close(g_ui_fd);
    g_ui_pid = 0;
    g_ui_fd = -1;
    g_page->cancel = 0;
    g_page->conflict_state = 0;
}

static void cmd_eexist(char **f)
{
    FileStat st;
    if (os_statat(AT_FDCWD, at(f[2], g_p2), &st, 0) < 0) { sc_put("E nosrc"); return; }
    for (size_t i = 0; i < 64; i++) g_out[i] = 0;
    SKIPFLAG = 0;
    FoOpenResult r = CALL(fo_resolve_eexist_open, g_basefd, f[1], &st, g_out);
    sc_put("E r="); sc_num(r.fd >= 0 ? 0 : r.fd); sc_put(" used="); sc_num(r.fd >= 0 ? (int64_t)(uint32_t)r.used : -1);
    sc_put(" out="); sc_esc(g_out[0] ? (str_starts_with(g_out, ".duop-ovw.") ? ".duop-ovw.<tmp>" : g_out) : "-");
    sc_put(" skip="); sc_num(SKIPFLAG);
    if (r.fd >= 0) { (void)os_write((int)r.fd, "new data", 8); (void)os_close((int)r.fd); }
    if (r.fd >= 0 && (uint32_t)r.used == 1) (void)os_renameat2(g_basefd, g_out, g_basefd, f[1], 0);   /* what the copy engine does */
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 3) return 2;
    g_ref = argv[1][0] == 'r';
    (void)str_copy(g_base, argv[2], PATH_MAX);
    g_basefd = (int)os_openat(AT_FDCWD, g_base, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    intptr_t m = os_mmap(nullptr, TASK_SHM_SIZE, PROT_RW, MAP_SHARED_ANON, -1, 0);
    if (m < 0 && m >= -4095) return 3;
    g_page = (TaskShared *)m;
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[24];
        int n = sc_split(line, f, 24);
        if (!n) continue;
        switch (f[0][0]) {
        case 'W': g_fs_progress = num(f[1]) ? g_page : nullptr; continue;
        case 'A': {
            stop_ui();
            int p[2];
            if (os_pipe2(p, O_CLOEXEC | O_NONBLOCK) < 0) continue;
            intptr_t pid = os_fork();
            if (pid == 0) { (void)os_close(p[0]); ui_child(f + 1, n - 1, p[1]); }
            (void)os_close(p[1]);
            g_ui_pid = (int)pid;
            g_ui_fd = p[0];
            continue;
        }
        case 'E': if (n < 3) continue; cmd_eexist(f); break;
        case 'M': if (n < 3) continue; for (size_t i = 0; i < 64; i++) g_out[i] = 0;
                  sc_put("M r="); sc_num(CALL(fo_move_check_conflict, at(f[1], g_p1), at(f[2], g_p2), g_out));
                  sc_put(" out="); sc_esc(g_out[0] ? g_out + (str_starts_with(g_out, g_base) ? str_len(g_base) : 0) : "-"); break;
        case 'Q': if (n < 4) continue; for (size_t i = 0; i < 64; i++) g_out[i] = 0;
                  sc_put("Q r="); sc_num(CALL(fs_task_resolve_conflict, g_basefd, f[1], (uint64_t)num(f[2]), (uint64_t)num(f[3]), g_out));
                  sc_put(" out="); sc_esc(g_out[0] ? g_out : "-"); break;
        default: continue;
        }
        sc_put("\n");
        (void)os_poll_in(-1, 5);
        drain_ui();
    }
    stop_ui();
    sc_flush();
    return 0;
}
