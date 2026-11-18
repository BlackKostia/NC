/* Freestanding harness: the frozen asm UI side of the background task (task_control_reference.s, x86_64, ref_ prefix) or
 * src/fs/task_control.c (compiled into this unit, path in TC_SRC), one implementation per process. Both read os_clock_ms through
 * tc_clock (scripted). A fake worker is forked by the harness. argv[1] = ref | c. Script on stdin:
 *   T <ms> [step]       the clock reads ms, advancing by step per call
 *   M <op>              a task page without a worker (for snapshots); g_task_op = op
 *   S <phase> <tb> <tf> <db> <df> <seq> <name> [paused] [pause_ms] [pause_at] [start_ms] [cancel_at]
 *                       writes the page / control state and prints fs_task_snapshot
 *   W <kind> [result]   forks a fake worker on a fresh page: d = waits for the cancel flag, then publishes -ECANCELED;
 *                       r = publishes result and exits; n = exits without a result; i = ignores every cancel (SIGTERM included);
 *                       c = ignores the flag but counts the SIGTERMs that interrupt its sleep (in total_files)
 *   R                   the harness reaps the worker itself (fs_task_poll then sees ECHILD)
 *   P                   fs_task_poll;  X  fs_task_toggle_pause (and the worker's process state);  K  fs_task_cancel;
 *   D                   fs_task_shutdown;  Z <ms>  real sleep */
#include "script_cli.h"
#include "duop_task.h"
#include "duop_pal.h"

int64_t tc_clock(void);
static int64_t g_now, g_step;
int64_t tc_clock(void) { int64_t v = g_now; g_now += g_step; return v; }

int g_task_wake_fd = -1, g_task_op;
int64_t g_task_start_ms;

#define os_clock_ms tc_clock
#include TC_SRC
#undef os_clock_ms

#ifdef __x86_64__
extern TaskShared *ref_g_task_shm;
extern int64_t ref_g_task_pause_ms, ref_g_task_cancel_at, ref_g_task_pause_at;
extern int ref_g_task_pid, ref_g_task_paused;
extern int ref_fs_task_poll(int64_t *);
extern void ref_fs_task_snapshot(TaskSnap *), ref_fs_task_cancel(void), ref_fs_task_shutdown(void);
extern int ref_fs_task_toggle_pause(void);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define V(x) (*(g_ref ? &ref_##x : &x))
#define PAUSE_AT (*(g_ref ? &ref_g_task_pause_at : &g_task_pause_at))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define V(x) (x)
#define PAUSE_AT g_task_pause_at
#endif

static bool g_ref;

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

static int64_t num(const char *s)
{
    bool neg = *s == '-';
    uint64_t v = 0;
    for (s += neg; *s >= '0' && *s <= '9'; s++) v = v * 10 + (uint64_t)(*s - '0');
    return neg ? -(int64_t)v : (int64_t)v;
}

static void put_u(uint64_t v) { char t[24]; t[u64_to_dec(v, t)] = 0; sc_put(t); }

static TaskShared *new_page(void)
{
    intptr_t m = os_mmap(nullptr, TASK_SHM_SIZE, PROT_RW, MAP_SHARED_ANON, -1, 0);
    return m < 0 && m >= -4095 ? nullptr : (TaskShared *)m;
}

static void cmd_snapshot(char **f, int n)
{
    TaskShared *s = V(g_task_shm);
    if (!s || n < 8) return;
    s->phase = (uint32_t)num(f[1]);
    s->total_bytes = (uint64_t)num(f[2]); s->total_files = (uint64_t)num(f[3]);
    s->done_bytes = (uint64_t)num(f[4]); s->done_files = (uint64_t)num(f[5]);
    s->seq = (uint32_t)num(f[6]);
    (void)str_copy(s->cur_name, f[7][0] == '-' ? "" : f[7], TASK_NAME_MAX);
    if (n > 8) V(g_task_paused) = (int)num(f[8]);
    if (n > 9) V(g_task_pause_ms) = num(f[9]);
    if (n > 10) PAUSE_AT = num(f[10]);
    if (n > 11) g_task_start_ms = num(f[11]);
    if (n > 12) V(g_task_cancel_at) = num(f[12]);
    TaskSnap snap;
    for (size_t i = 0; i < sizeof snap; i++) ((uint8_t *)&snap)[i] = 0xA5;
    CALL(fs_task_snapshot, &snap);
    sc_put("S t="); put_u(snap.total_bytes); sc_put("/"); put_u(snap.total_files); sc_put(" d="); put_u(snap.done_bytes); sc_put("/"); put_u(snap.done_files);
    sc_put(" el="); put_u(snap.elapsed_ms); sc_put(" bps="); put_u(snap.speed_bps); sc_put(" eta="); put_u(snap.eta_sec);
    sc_put(" op="); sc_num(snap.op); sc_put(" ph="); sc_num(snap.phase); sc_put(" pa="); sc_num(snap.paused); sc_put(" pct="); sc_num(snap.percent);
    sc_put(" cx="); sc_num(snap.canceling); sc_put(" pad="); sc_num(snap.pad); sc_put(" name="); sc_esc(snap.cur_name);
}

[[noreturn]] static void fake_worker(TaskShared *s, char kind, int64_t result, int wfd)
{
    (void)wfd;
    os_signals_worker_mode();                                          /* SIGTERM interrupts, it does not kill */
    __atomic_store_n(&s->conflict_state, 99u, __ATOMIC_RELEASE);        /* ready: the parent may signal now */
    if (kind == 'n') os_exit(3);
    if (kind == 'r') { s->result = result; s->phase = TASK_PHASE_DONE; os_exit(0); }
    for (;;) {
        if (kind == 'c') { if (os_poll_in(-1, 10000) == -EINTR) s->total_files++; continue; }
        (void)os_poll_in(-1, 5);
        if (kind == 'd' && s->cancel) { s->result = -ECANCELED; s->phase = TASK_PHASE_DONE; os_exit(0); }
    }
}

static void cmd_worker(char **f, int n)
{
    TaskShared *s = new_page();
    int p[2];
    if (!s || os_pipe_cloexec(p) < 0) return;
    s->phase = TASK_PHASE_RUN;
    intptr_t pid = os_fork();
    if (pid == 0) { (void)os_close(p[0]); fake_worker(s, f[1][0], n > 2 ? num(f[2]) : 0, p[1]); }
    (void)os_close(p[1]);
    for (int i = 0; i < 400 && __atomic_load_n(&s->conflict_state, __ATOMIC_ACQUIRE) != 99u; i++) (void)os_poll_in(-1, 5);
    V(g_task_pid) = (int)pid;
    V(g_task_shm) = s;
    g_task_wake_fd = p[0];
    g_task_start_ms = tc_clock();
    sc_put("W ok");
}

static char proc_state(int pid)
{
    char path[48] = "/proc/", t[24], buf[256];
    size_t k = u64_to_dec((uint64_t)pid, t), n = 6;
    for (size_t i = 0; i < k; i++) path[n++] = t[i];
    (void)str_copy(path + n, "/stat", 8);
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) return '-';
    intptr_t r = os_read((int)fd, buf, sizeof buf - 1);
    (void)os_close((int)fd);
    for (intptr_t i = r - 1; i > 0; i--)
        if (buf[i] == ')' && i + 2 < r) return buf[i + 2];
    return '?';
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[16];
        int n = sc_split(line, f, 16);
        if (!n) continue;
        switch (f[0][0]) {
        case 'T': g_now = num(f[1]); g_step = n > 2 ? num(f[2]) : 0; continue;
        case 'M': V(g_task_shm) = new_page(); g_task_op = (int)num(f[1]); continue;
        case 'S': cmd_snapshot(f, n); break;
        case 'W': cmd_worker(f, n); break;
        case 'P': { int64_t res = 777; int r = CALL(fs_task_poll, &res); sc_put("P "); sc_num(r); sc_put(" res="); sc_num(res);
                    sc_put(" pid="); sc_num(V(g_task_pid) != 0); sc_put(" shm="); sc_num(V(g_task_shm) != nullptr); sc_put(" wfd="); sc_num(g_task_wake_fd); break; }
        case 'X': { int pid = V(g_task_pid); int r = CALL(fs_task_toggle_pause); (void)os_poll_in(-1, 30); char st[2] = {pid ? proc_state(pid) : '-', 0};
                    sc_put("X "); sc_num(r); sc_put(" state="); sc_put(st[0] == 'S' || st[0] == 'R' ? "run" : st[0] == 'T' || st[0] == 't' ? "stop" : st);
                    sc_put(" pms="); sc_num(V(g_task_pause_ms)); break; }
        case 'K': CALL(fs_task_cancel); sc_put("K cx="); sc_num(V(g_task_cancel_at)); sc_put(" flag="); sc_num(V(g_task_shm) ? (int64_t)V(g_task_shm)->cancel : -1);
                  sc_put(" paused="); sc_num(V(g_task_paused)); break;
        case 'D': CALL(fs_task_shutdown); sc_put("D pid="); sc_num(V(g_task_pid)); sc_put(" wfd="); sc_num(g_task_wake_fd); break;
        case 'R': { int st; while (os_wait4(V(g_task_pid), &st, 0, nullptr) == -EINTR) {} continue; }
        case 'N': sc_put("N sigterms="); sc_num(V(g_task_shm) ? (int64_t)V(g_task_shm)->total_files : -1); break;
        case 'Z': (void)os_poll_in(-1, (int)num(f[1])); continue;
        default: continue;
        }
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
