/* Freestanding harness: the frozen asm task worker (task_reference.s + task_worker_reference.s, x86_64, ref_ prefix) or
 * src/fs/task.c + task_worker.c (compiled into this unit, paths in TK_SRC1 / TK_SRC2). The copy / move / delete engines are the C
 * modules; the task_control.s globals and the conflict policies are stand-ins here. argv = <ref|c> <base dir>; "@" stands for the
 * base dir. Script on stdin:
 *   J <op> <join> <src_dir> <dst> <name>...   fs_task_start; then (unless the start failed) wait for the hang-up of the wake fd,
 *                                             reap the worker and print the shared page
 *   B <op> <join> <src_dir> <dst> <name>...   two starts in a row: the second must answer -EBUSY
 *   K <n>                                     the conflict stand-in requests a cancel at its n-th call (0: never) */
#include "script_cli.h"
#include "duop_task.h"
#include "duop_pal.h"

int g_task_pid, g_task_paused;
int64_t g_task_pause_ms, g_task_cancel_at;
TaskShared *g_task_shm;
int g_copy_had_skip;
static int64_t g_cancel_at_conflict;
static bool g_ref;

#ifdef __x86_64__
extern intptr_t ref_fs_task_start(const TaskJob *);
extern int ref_fs_task_is_active(void), ref_fs_task_wake_fd(void);
extern void ref_fs_progress_begin(const char *), ref_fs_progress_bytes(uint64_t), ref_fs_progress_item(void);
extern int ref_fs_progress_cancelled(void);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define HOOK(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : c_##f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define HOOK(f, ...) c_##f(__VA_ARGS__)
#endif
#define PROGRESS g_fs_progress            /* one set of globals: the oracle's are weakened onto the C module's */

static void conflict_tick(void)
{
    if (g_cancel_at_conflict > 0 && --g_cancel_at_conflict == 0 && PROGRESS) PROGRESS->cancel = 1;
}

FoOpenResult fo_resolve_eexist_open(int dst_dfd, const char *dst_rel, const FileStat *src_st, char *out_ren);
FoOpenResult fo_resolve_eexist_open(int dst_dfd, const char *dst_rel, const FileStat *src_st, char *out_ren)
{
    conflict_tick();
    FileStat dst;
    if (os_statat(dst_dfd, dst_rel, &dst, 0) < 0) return (FoOpenResult){-ENOENT, 0};
    return fo_open_overwrite(dst_dfd, dst_rel, dst.mode, src_st->mode & 07777, out_ren);
}

intptr_t fo_move_check_conflict(const char *src, const char *dst, char *out_ren);
intptr_t fo_move_check_conflict(const char *src, const char *dst, char *out_ren)
{
    (void)src; (void)dst; (void)out_ren;
    conflict_tick();
    return 1;
}

/* the copy / move / delete engines call the hooks of the implementation under test */
#define fs_progress_begin c_fs_progress_begin
#define fs_progress_bytes c_fs_progress_bytes
#define fs_progress_item c_fs_progress_item
#define fs_progress_cancelled c_fs_progress_cancelled
void c_fs_progress_begin(const char *path);
void c_fs_progress_bytes(uint64_t n);
void c_fs_progress_item(void);
int c_fs_progress_cancelled(void);
#include TK_SRC1
#include TK_SRC2
#undef fs_progress_begin
#undef fs_progress_bytes
#undef fs_progress_item
#undef fs_progress_cancelled
void fs_progress_begin(const char *path) { HOOK(fs_progress_begin, path); }
void fs_progress_bytes(uint64_t n) { HOOK(fs_progress_bytes, n); }
void fs_progress_item(void) { HOOK(fs_progress_item); }
int fs_progress_cancelled(void) { return HOOK(fs_progress_cancelled); }

static char g_base[PATH_MAX];
static TaskJob *g_job;

static void at(const char *p, char *out)
{
    size_t n = 0;
    if (p[0] == '@') { n = str_copy(out, g_base, PATH_MAX); p++; }
    (void)str_copy(out + n, p, PATH_MAX - n);
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

static bool make_job(char **f, int n)
{
    mem_free(g_job);
    g_job = mem_alloc(sizeof(TaskJob) + 8192);
    if (!g_job) return false;
    mem_zero(g_job, sizeof(TaskJob) + 8192);
    g_job->op = (uint32_t)num(f[1]);
    g_job->join_dst = (uint32_t)num(f[2]);
    at(f[3], g_job->src_dir);
    at(f[4], g_job->dst);
    size_t len = 0;
    for (int i = 5; i < n; i++) len += str_copy(g_job->names + len, f[i][0] == '%' ? "" : f[i], 4096) + 1;
    g_job->count = (uint32_t)(n - 5);
    g_job->names_len = len;
    return true;
}

static void wait_done(void)
{
    int fd = CALL(fs_task_wake_fd);
    char c;
    for (int i = 0; i < 500; i++) {                                   /* the write end closes when the worker exits (10 s) */
        (void)os_poll_in(fd, 20);
        intptr_t r = os_read(fd, &c, 1);
        if (r == 0) break;
    }
    int status = 0;
    while (os_wait4(g_task_pid, &status, 0, nullptr) == -EINTR) {}
    TaskShared *s = g_task_shm;
    sc_put(" res="); sc_num(s->result); sc_put(" phase="); sc_num(s->phase); sc_put(" exit="); sc_num(status);
    sc_put(" total="); sc_num((int64_t)s->total_files); sc_put("/"); sc_num((int64_t)s->total_bytes);
    sc_put(" done="); sc_num((int64_t)s->done_files); sc_put("/"); sc_num((int64_t)s->done_bytes);
    sc_put(" seq_even="); sc_num(!(s->seq & 1)); sc_put(" cur="); sc_esc(s->cur_name);
    sc_put(" active="); sc_num(CALL(fs_task_is_active));
    (void)os_close(fd);
    (void)os_munmap_raw(s, TASK_SHM_SIZE);
    g_task_pid = 0;
    g_task_shm = nullptr;
    sc_put(" after="); sc_num(CALL(fs_task_is_active)); sc_put(","); sc_num(CALL(fs_task_wake_fd));
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 3) return 2;
    g_ref = argv[1][0] == 'r';
    (void)str_copy(g_base, argv[2], PATH_MAX);
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[40];
        int n = sc_split(line, f, 40);
        if (!n) continue;
        if (f[0][0] == 'K') { g_cancel_at_conflict = num(f[1]); continue; }
        if ((f[0][0] != 'J' && f[0][0] != 'B') || n < 5 || !make_job(f, n)) continue;
        intptr_t r = CALL(fs_task_start, g_job);
        sc_put(f[0]); sc_put(" start="); sc_num(r);
        if (f[0][0] == 'B' && r == 0) { sc_put(" again="); sc_num(CALL(fs_task_start, g_job)); }
        if (r == 0) wait_done();
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
