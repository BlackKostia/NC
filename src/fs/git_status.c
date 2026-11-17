/* src/fs/git_status.c - git branch and `git status --porcelain=v1 -z` integration of the file panes (freestanding C23; replaces
 * git_status.s + git_status_query.s, kept as tests/harness/git_status_reference.s and git_status_query_reference.s).
 *
 * git_refresh() runs `git status` once per directory change - only inside a trusted repository (git_trust.c), with
 * core.fsmonitor off, submodules ignored, no optional locks, stdin/stderr on /dev/null and a fixed environment - and keeps the
 * branch plus one status character per top-level name of the directory. A git that is not done within GIT_TIMEOUT_MS is killed
 * and switches the integration off for the rest of the session: a dead mount or a huge repository never freezes the UI. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define GIT_MAX_ENTRIES 512
#define GIT_BUF_SIZE 65536
#define GIT_TIMEOUT_MS 2500
#define GIT_NAME_MAX 255
#define GIT_BRANCH_MAX 63

typedef struct GitEntry { char name[GIT_NAME_MAX + 1]; uint8_t status, pad[3]; } GitEntry;
typedef struct GitCtx { char branch[GIT_BRANCH_MAX + 1]; int32_t count, pad; GitEntry *entries; } GitCtx;
_Static_assert(sizeof(GitEntry) == 260 && sizeof(GitCtx) == 80, "GENT_SIZE / GCTX_SIZE of the assembler");

int g_git_defer;               /* 1 until the first frame is drawn: start-up never waits for git */
static int g_git_off;          /* 1 after a git run exceeded its deadline: git integration stays off */

static const char git_no_commits[] = "No commits yet on ";

void git_free_ctx(DirModel *dm)
{
    GitCtx *ctx = dm->git_ctx;
    if (!ctx) return;
    mem_free(ctx->entries);
    mem_free(ctx);
    dm->git_ctx = nullptr;
}

/* execs git from each PATH entry of the process environment, then from the usual places; returns only when all fail */
static void git_exec_from_path(char *const argv[], char *const envp[])
{
    char cand[PATH_MAX + 8];
    const char *p = env_getenv(g_envp, "PATH");
    while (p && *p) {
        size_t n = 0;
        bool too_long = false;
        for (; *p && *p != ':'; p++) {
            if (n < PATH_MAX - 8) cand[n++] = *p;
            else too_long = true;                        /* never exec a truncated directory name */
        }
        if (*p == ':') p++;
        if (!n || too_long) continue;
        mem_copy(cand + n, "/git", 5);
        (void)os_execve(cand, argv, envp);
    }
    (void)os_execve("/usr/bin/git", argv, envp);
    (void)os_execve("/usr/local/bin/git", argv, envp);
    (void)os_execve("/bin/git", argv, envp);
}

[[noreturn]] static void git_child(const char *dir, const int pfd[2])
{
    (void)os_dup2(pfd[1], 1);
    (void)os_close(pfd[0]);
    (void)os_close(pfd[1]);
    intptr_t nul = os_openat(AT_FDCWD, "/dev/null", O_RDWR, 0);
    if (nul >= 0) {
        (void)os_dup2((int)nul, 2);
        (void)os_dup2((int)nul, 0);                      /* stdin: the helper must never read the user's keystrokes */
        (void)os_close((int)nul);
    }
    const char *argv[] = {"git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", dir, "status", "--porcelain=v1",
                          "--ignore-submodules=all", "-z", "-b", nullptr};
    const char *envp[] = {"PATH=/usr/bin:/bin", "LC_ALL=C", nullptr};
    os_sig_reset_pipe();
    os_mark_child_forked();
    git_exec_from_path((char *const *)argv, (char *const *)envp);
    os_exit(127);
}

/* reads the child's stdout until EOF, a full buffer or the deadline (then the child is killed and nothing is kept) */
static uint32_t git_read_all(int fd, int pid, char *buf, uint32_t room)
{
    uint32_t got = 0;
    int64_t deadline = os_clock_ms() + GIT_TIMEOUT_MS;
    while (got < room) {
        int64_t left = deadline - os_clock_ms();
        intptr_t r = left > 0 ? os_poll_in(fd, (int)left) : 0;
        if (r == -EINTR) continue;
        if (r == 0) {                                    /* nothing readable before the deadline */
            g_git_off = 1;                               /* too slow once: leave git alone for the rest of the session */
            (void)os_kill(pid, SIGKILL);
            return 0;                                    /* drop partial output */
        }
        if (r < 0) break;
        r = os_read(fd, buf + got, room - got);
        if (r == -EINTR) continue;
        if (r <= 0) break;
        got += (uint32_t)r;
    }
    return got;
}

/* runs git status in dir: bytes of output (NUL-terminated in out_buf), or -1 */
int git_spawn_status(const char *dir, char *out_buf, int buf_cap)
{
    int pfd[2];
    if (g_git_off || os_pipe2(pfd, O_CLOEXEC) < 0) return -1;
    intptr_t pid = os_fork();
    if (pid < 0) {
        (void)os_close(pfd[0]);
        (void)os_close(pfd[1]);
        return -1;
    }
    if (pid == 0) git_child(dir, pfd);
    (void)os_close(pfd[1]);
    uint32_t got = git_read_all(pfd[0], (int)pid, out_buf, (uint32_t)(buf_cap - 1));
    (void)os_close(pfd[0]);
    int status = 0;
    intptr_t w;
    while ((w = os_wait4((int)pid, &status, 0, nullptr)) == -EINTR) {}
    if (w < 0 || status) return -1;
    out_buf[got] = 0;
    return (int)got;
}

/* "## <branch>[...<upstream>...]" (or "## No commits yet on <branch>") at *p_cur -> ctx->branch (63 bytes at most, stops at ".."
 * or the end of the record); *p_cur moves past the record. Anything else leaves both untouched. */
void git_parse_branch(char *branch, const char **p_cur, const char *end)
{
    const char *p = *p_cur;
    if (p >= end || p[0] != '#' || p[1] != '#' || p[2] != ' ') return;
    p += 3;
    size_t k = 0;
    while (git_no_commits[k] && p[k] == git_no_commits[k]) k++;
    if (!git_no_commits[k]) p += k;
    size_t n = 0;
    for (; p < end; p++) {
        char c = *p;
        if (!c || c == '\n' || (c == '.' && p[1] == '.')) {
            while (p < end && *p) p++;                   /* skip the rest of the record */
            if (p < end) p++;
            break;
        }
        if (n < GIT_BRANCH_MAX) branch[n++] = c;
    }
    branch[n] = 0;
    *p_cur = p;
}

/* the status character shown for an "XY path" record: untracked '?', else the work-tree column Y, else the index column X */
static uint8_t git_status_char(uint8_t x, uint8_t y)
{
    return x == '?' || y == ' ' || !y ? x : y;
}

/* past the NUL that ends the string at p (or end) */
static const char *git_skip_str(const char *p, const char *end, bool *found)
{
    while (p < end && *p) p++;
    *found = p < end;
    return *found ? p + 1 : p;
}

/* porcelain v1 -z output -> branch + one entry per record (the name up to its first '/', i.e. the top-level name) */
static void git_parse_output(GitCtx *ctx, const char *buf, int len)
{
    const char *cur = buf, *end = buf + len;
    git_parse_branch(ctx->branch, &cur, end);
    while (cur + 4 < end) {
        uint8_t st = git_status_char((uint8_t)cur[0], (uint8_t)cur[1]);
        const char *path = cur + 3;
        bool found;
        cur = git_skip_str(path, end, &found);
        if (found && (path[-3] == 'R' || path[-3] == 'C')) cur = git_skip_str(cur, end, &found);   /* the original name of a rename / copy */
        if (ctx->count >= GIT_MAX_ENTRIES) continue;
        GitEntry *e = &ctx->entries[ctx->count++];
        size_t n = 0;
        while (n < GIT_NAME_MAX && path[n] && path[n] != '/') { e->name[n] = path[n]; n++; }
        e->name[n] = 0;
        e->status = st;
    }
}

/* 1 when dir or one of its ancestors has a .git that git_repo_trusted() accepts. The probe "<dir>/.git" is built in place; a
 * probe that would not fit PATH_MAX is skipped instead of being truncated into a different path. */
static int git_has_repo(const char *dir)
{
    char cur[PATH_MAX + 8];
    FileStat st;
    (void)str_copy(cur, dir, PATH_MAX);
    for (;;) {
        size_t len = str_len(cur);
        size_t base = len == 1 && cur[0] == '/' ? 0 : len;           /* "/" + "/.git" would be "//.git" */
        if (base + 5 < PATH_MAX) {
            mem_copy(cur + base, "/.git", 6);
            if (os_statat(AT_FDCWD, cur, &st, 0) == 0) return git_repo_trusted(cur);
            cur[base] = 0;
            if (!base) { cur[0] = '/'; cur[1] = 0; }
        }
        if (len <= 1) return 0;
        size_t i = len - 1;
        while (i && cur[i] != '/') i--;
        if (!i) return 0;                                            /* "/name": the root itself is not probed (as before) */
        cur[i] = 0;
    }
}

int git_refresh(DirModel *dm)
{
    if (g_git_defer || dm->virtual_mode) return 0;
    GitCtx *ctx = dm->git_ctx;
    if (!git_has_repo(dm->path)) {
        if (ctx) { ctx->branch[0] = 0; ctx->count = 0; }
        return 0;
    }
    if (!ctx) {
        ctx = mem_alloc(sizeof *ctx);
        if (!ctx) return 0;
        mem_zero(ctx, sizeof *ctx);
        ctx->entries = mem_alloc(GIT_MAX_ENTRIES * sizeof(GitEntry));
        if (!ctx->entries) { mem_free(ctx); return 0; }
        dm->git_ctx = ctx;
    }
    ctx->branch[0] = 0;
    ctx->count = 0;
    char *buf = mem_alloc(GIT_BUF_SIZE);
    if (!buf) return 0;
    int n = git_spawn_status(dm->path, buf, GIT_BUF_SIZE);
    if (n > 0) git_parse_output(ctx, buf, n);
    mem_free(buf);
    return 0;
}

/* status character of name in dm's repository listing, or 0 */
int git_lookup(DirModel *dm, const char *name)
{
    if (!dm || !name || dm->virtual_mode) return 0;
    const GitCtx *ctx = dm->git_ctx;
    if (!ctx) return 0;
    for (int i = 0; i < ctx->count; i++)
        if (!str_cmp(ctx->entries[i].name, name)) return ctx->entries[i].status;
    return 0;
}

const char *git_branch(DirModel *dm)
{
    if (!dm || dm->virtual_mode) return "";
    const GitCtx *ctx = dm->git_ctx;
    return ctx && ctx->branch[0] ? ctx->branch : "";
}
