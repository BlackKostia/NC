/* Freestanding harness: the frozen asm git integration (git_status_reference.s + git_status_query_reference.s, x86_64, ref_
 * prefix) or src/fs/git_status.c (compiled into this unit, path in GS_SRC); argv = <ref|c> <step_ms> <poll: r|z>, one
 * implementation per process (g_git_off / g_git_defer are global). Both call gs_clock / gs_poll instead of os_clock_ms /
 * os_poll_in and gs_alloc instead of mem_alloc:
 *   step 0  the real clock            step k  each clock call returns k * (number of calls)
 *   poll r  a real poll (the timeout argument is recorded)     poll z  poll returns 0 at once (nothing readable)
 *   poll s  a real poll, then 300 ms of sleep (the stand-in git has exited by the next step)
 * Script on stdin, one command per line:
 *   R <path> [V]       git_refresh on a model at path (V: virtual mode); prints the branch and every entry
 *   L <name>           git_lookup;  N  git_branch;  D <0|1>  g_git_defer;  F  git_free_ctx;  O <n>  the n-th allocation fails
 *   P <dir> <cap>      git_spawn_status on its own: result and the output (escaped)
 *   B <hex bytes>      git_parse_branch: branch and how many bytes were consumed */
#include "script_cli.h"
#include "duop_fs.h"

int64_t gs_clock(void);
int gs_poll(int fd, int timeout_ms);
void *gs_alloc(size_t n);

static int64_t g_step, g_clock_calls, g_fail_in;
static char g_poll_mode;
static char g_polls[512];
static size_t g_polls_n;

int64_t gs_clock(void)
{
    g_clock_calls++;
    return g_step ? g_step * g_clock_calls : os_clock_ms();
}

int gs_poll(int fd, int timeout_ms)
{
    if (g_polls_n < sizeof g_polls - 24) {
        char t[24];
        g_polls[g_polls_n++] = ' ';
        if (timeout_ms < 0) { g_polls[g_polls_n++] = '-'; timeout_ms = -timeout_ms; }
        size_t k = u64_to_dec((uint64_t)timeout_ms, t);
        for (size_t i = 0; i < k; i++) g_polls[g_polls_n++] = t[i];
    }
    if (g_poll_mode == 'z') return 0;
    int r = os_poll_in(fd, timeout_ms);
    if (g_poll_mode == 's') (void)os_poll_in(-1, 300);                 /* let a finished child exit before the next step */
    return r;
}

void *gs_alloc(size_t n)
{
    if (g_fail_in > 0 && --g_fail_in == 0) return nullptr;
    return mem_alloc(n);
}

#define os_clock_ms gs_clock
#define os_poll_in gs_poll
#define mem_alloc gs_alloc
#include GS_SRC
#undef os_clock_ms
#undef os_poll_in
#undef mem_alloc

#ifdef __x86_64__
#define REF(f) ref_##f
extern int ref_git_refresh(DirModel *);
extern int ref_git_lookup(DirModel *, const char *);
extern const char *ref_git_branch(DirModel *);
extern void ref_git_free_ctx(DirModel *);
extern int ref_git_spawn_status(const char *, char *, int);
extern void ref_git_parse_branch(char *, const char **, const char *);
extern int ref_g_git_defer;
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define DEFER (*(g_ref ? &ref_g_git_defer : &g_git_defer))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define DEFER g_git_defer
#endif

static bool g_ref;
static DirModel g_dm;
static char g_out[GIT_BUF_SIZE];

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

static int hexv(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : 0; }

static void put_bytes(const char *p, size_t n)
{
    static const char hx[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        uint8_t c = (uint8_t)p[i];
        if (c >= 0x21 && c < 0x7F && c != '\\') { char t[2] = {(char)c, 0}; sc_put(t); }
        else { char t[5] = {'\\', 'x', hx[c >> 4], hx[c & 15], 0}; sc_put(t); }
    }
}

static void put_ctx(void)
{
    const GitCtx *ctx = g_dm.git_ctx;
    sc_put(" ctx="); sc_num(ctx != nullptr);
    sc_put(" branch="); sc_esc(CALL(git_branch, &g_dm));
    if (!ctx) return;
    sc_put(" raw="); sc_esc(ctx->branch);
    sc_put(" n="); sc_num(ctx->count);
    for (int i = 0; i < ctx->count && i < GIT_MAX_ENTRIES; i++) {
        sc_put(" "); sc_esc(ctx->entries[i].name); sc_put(":");
        char t[2] = {(char)ctx->entries[i].status, 0}; sc_esc(t);
    }
}

static void cmd(char **f, int n)
{
    switch (f[0][0]) {
    case 'R':
        if (n < 2) return;
        (void)str_copy(g_dm.path, f[1], PATH_MAX);
        g_dm.virtual_mode = n > 2 && f[2][0] == 'V';
        g_polls_n = 0;
        {
            int r = CALL(git_refresh, &g_dm);                /* deferred: the asm left the caller's eax in place, C returns 0 */
            sc_put("R r=");
            if (DEFER) sc_put("deferred"); else sc_num(r);
        }
        put_ctx();
        g_polls[g_polls_n] = 0; sc_put(" polls=["); sc_put(g_polls); sc_put(" ]");
        break;
    case 'L': if (n >= 2) { sc_put("L "); sc_esc(f[1]); sc_put(" ="); sc_num(CALL(git_lookup, &g_dm, f[1])); } break;
    case 'N': sc_put("N "); sc_esc(CALL(git_branch, &g_dm)); break;
    case 'D': if (n >= 2) { DEFER = (int)num(f[1]); sc_put("D"); } break;
    case 'F': CALL(git_free_ctx, &g_dm); sc_put("F ctx="); sc_num(g_dm.git_ctx != nullptr); break;
    case 'O': if (n >= 2) { g_fail_in = num(f[1]); sc_put("O"); } break;
    case 'P': {
        if (n < 3) return;
        for (size_t i = 0; i < sizeof g_out; i++) g_out[i] = (char)0xA5;
        int r = CALL(git_spawn_status, f[1], g_out, (int)num(f[2]));
        sc_put("P r="); sc_num(r); sc_put(" out=");
        if (r >= 0) put_bytes(g_out, (size_t)r + 1);
        break;
    }
    case 'B': {
        if (n < 2) return;
        size_t len = str_len(f[1]) / 2;
        for (size_t i = 0; i < len; i++) g_out[i] = (char)(hexv(f[1][2 * i]) << 4 | hexv(f[1][2 * i + 1]));
        g_out[len] = 0;
        char br[64];
        for (size_t i = 0; i < sizeof br; i++) br[i] = '~';
        br[63] = 0;
        const char *cur = g_out;
        CALL(git_parse_branch, br, &cur, g_out + len);
        sc_put("B used="); sc_num(cur - g_out); sc_put(" br="); put_bytes(br, str_len(br));
        break;
    }
    default: return;
    }
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 4) return 2;
    g_envp = envp;
    g_ref = argv[1][0] == 'r';
    g_step = num(argv[2]);
    g_poll_mode = argv[3][0];
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[4];
        int n = sc_split(line, f, 4);
        if (n) cmd(f, n);
    }
    sc_flush();
    return 0;
}
