/* src/fs/nav_persist.c - persistent navigation state (freestanding C23; replaces nav_state_bookmarks.s, nav_state_frecency.s
 * and the init / cleanup half of nav_state.s): the data directory ($XDG_DATA_HOME/duop or $HOME/.local/share/duop), the
 * bookmark list ("bookmarks": one path per line, at most 64) and the frecency list ("frecency": "<score> <path>" lines, at
 * most 128, best first). Both files are loaded once by nav_state_init and rewritten atomically (temp file + fsync + rename)
 * after every change. */
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define NAV_FILE_MAX 16383                          /* bytes of a state file that are read */

static char g_data_dir[PATH_MAX];
static int32_t g_data_ready;
static int32_t g_bm_cnt;
static char *g_bm_ptrs[NAV_BM_MAX];
static int32_t g_fre_cnt;
static uint32_t g_fre_scores[NAV_FRE_MAX];
static char *g_fre_ptrs[NAV_FRE_MAX];

static const char *nav_find_env(const char *const *envp, const char *prefix)
{
    if (!envp) return nullptr;
    for (; *envp; envp++)
        if (str_starts_with(*envp, prefix)) return *envp + str_len(prefix);
    return nullptr;
}

static void nav_mkdir_p(const char *path)           /* every missing component, 0755; errors ignored */
{
    char p[PATH_MAX];
    str_copy(p, path, PATH_MAX);
    for (char *s = p + 1; *s; s++) {
        if (*s != '/') continue;
        *s = 0;
        (void)os_mkdirat(AT_FDCWD, p, 0755);
        *s = '/';
    }
    (void)os_mkdirat(AT_FDCWD, p, 0755);
}

/* reads <data dir>/<name> into a heap block whose text starts at PATH_MAX (NUL-terminated); NULL when absent, empty or out of memory */
static char *nav_read_state(const char *name)
{
    char *blk = mem_alloc(PATH_MAX + NAV_FILE_MAX + 1);
    if (!blk) return nullptr;
    char *data = blk + PATH_MAX;
    (void)path_join(blk, g_data_dir, name, PATH_MAX);
    intptr_t fd = os_openat(AT_FDCWD, blk, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) { mem_free(blk); return nullptr; }
    intptr_t n = sys_read_retry((int)fd, data, NAV_FILE_MAX);
    os_close((int)fd);
    if (n <= 0) { mem_free(blk); return nullptr; }
    data[n] = 0;
    return blk;
}

static char *nav_next_line(char **pp)               /* NUL-terminates the next line and advances *pp */
{
    char *s = *pp, *e = s;
    while (*e && *e != '\n') e++;
    if (*e) *e++ = 0;
    *pp = e;
    return s;
}

/* atomic rewrite of <data dir>/<name>: blk holds the final path, blk + PATH_MAX the temp path */
static char *nav_save_open(const char *name, intptr_t *fd)
{
    char *blk = mem_alloc(2 * PATH_MAX);
    if (!blk) return nullptr;
    if (path_join(blk, g_data_dir, name, PATH_MAX) >= 0) {
        *fd = tmp_open_atomic(blk, blk + PATH_MAX, 0644);
        if (*fd >= 0) return blk;
    }
    mem_free(blk);
    return nullptr;
}

static void nav_save_close(char *blk, intptr_t fd, intptr_t write_rc)
{
    (void)tmp_commit_atomic((int)fd, blk + PATH_MAX, blk, write_rc < 0 ? write_rc : 0);
    mem_free(blk);
}

/* ---- bookmarks ---- */

static void nav_bookmarks_load(void)
{
    char *blk = nav_read_state("bookmarks");
    if (!blk) return;
    for (char *p = blk + PATH_MAX; *p && g_bm_cnt < NAV_BM_MAX;) {
        char *line = nav_next_line(&p);
        char *dup = *line ? nav_strdup(line) : nullptr;
        if (dup) g_bm_ptrs[g_bm_cnt++] = dup;
    }
    mem_free(blk);
}

static void nav_bookmarks_save(void)
{
    intptr_t fd, rc = 0;
    if (!g_data_ready) return;
    char *blk = nav_save_open("bookmarks", &fd);
    if (!blk) return;
    for (int i = 0; i < g_bm_cnt && rc >= 0; i++) {
        if (!g_bm_ptrs[i]) continue;
        rc = sys_write_all((int)fd, g_bm_ptrs[i], str_len(g_bm_ptrs[i]));
        if (rc >= 0) rc = sys_write_all((int)fd, "\n", 1);
    }
    nav_save_close(blk, fd, rc);
}

int nav_bookmarks_count(void) { return g_bm_cnt; }

const char *nav_bookmarks_get(int idx) { return idx >= 0 && idx < g_bm_cnt ? g_bm_ptrs[idx] : nullptr; }

int nav_bookmarks_add(const char *path)                  /* 1 added, 0 duplicate / full / empty / out of memory */
{
    if (!path || !*path) return 0;
    for (int i = 0; i < g_bm_cnt; i++)
        if (!str_cmp(g_bm_ptrs[i], path)) return 0;
    if (g_bm_cnt >= NAV_BM_MAX) return 0;
    char *dup = nav_strdup(path);
    if (!dup) return 0;
    g_bm_ptrs[g_bm_cnt++] = dup;
    nav_bookmarks_save();
    return 1;
}

void nav_bookmarks_remove(int idx)
{
    if (idx < 0 || idx >= g_bm_cnt) return;
    mem_free(g_bm_ptrs[idx]);
    for (int i = idx; i < g_bm_cnt - 1; i++) g_bm_ptrs[i] = g_bm_ptrs[i + 1];
    g_bm_ptrs[--g_bm_cnt] = nullptr;
    nav_bookmarks_save();
}

/* ---- frecency ("z"): visit counts, best first ---- */

static void nav_frecency_load(void)
{
    char *blk = nav_read_state("frecency");
    if (!blk) return;
    for (char *p = blk + PATH_MAX; *p && g_fre_cnt < NAV_FRE_MAX;) {
        char *q = nav_next_line(&p);
        uint32_t score = 0;
        for (; *q >= '0' && *q <= '9'; q++) score = score * 10 + (uint32_t)(*q - '0');
        if (*q != ' ' || !q[1]) continue;
        char *dup = nav_strdup(q + 1);
        if (!dup) continue;
        g_fre_scores[g_fre_cnt] = score ? score : 1;
        g_fre_ptrs[g_fre_cnt++] = dup;
    }
    mem_free(blk);
}

static void nav_frecency_save(void)
{
    intptr_t fd, rc = 0;
    if (!g_data_ready) return;
    char *blk = nav_save_open("frecency", &fd);
    if (!blk) return;
    for (int i = 0; i < g_fre_cnt && rc >= 0; i++) {
        char num[24];
        size_t n = u64_to_dec(g_fre_scores[i], num);
        num[n++] = ' ';
        rc = sys_write_all((int)fd, num, n);
        if (rc >= 0) rc = sys_write_all((int)fd, g_fre_ptrs[i], str_len(g_fre_ptrs[i]));
        if (rc >= 0) rc = sys_write_all((int)fd, "\n", 1);
    }
    nav_save_close(blk, fd, rc);
}

void nav_frecency_record(const char *path)               /* one more visit of path; the best entries bubble to the front */
{
    if (!path || !*path) return;
    int i = 0;
    while (i < g_fre_cnt && str_cmp(g_fre_ptrs[i], path)) i++;
    if (i < g_fre_cnt) {
        g_fre_scores[i]++;
    } else {
        char *dup = nav_strdup(path);                    /* allocate first: a failure leaves the list untouched */
        if (!dup) return;
        if (g_fre_cnt < NAV_FRE_MAX) {
            i = g_fre_cnt++;
        } else {
            i = NAV_FRE_MAX - 1;                         /* the lowest entry makes room */
            mem_free(g_fre_ptrs[i]);
        }
        g_fre_ptrs[i] = dup;
        g_fre_scores[i] = 1;
    }
    for (; i > 0 && (int32_t)g_fre_scores[i] > (int32_t)g_fre_scores[i - 1]; i--) {
        uint32_t s = g_fre_scores[i];
        g_fre_scores[i] = g_fre_scores[i - 1];
        g_fre_scores[i - 1] = s;
        char *p = g_fre_ptrs[i];
        g_fre_ptrs[i] = g_fre_ptrs[i - 1];
        g_fre_ptrs[i - 1] = p;
    }
    nav_frecency_save();
}

int nav_frecency_count(void) { return g_fre_cnt; }

const char *nav_frecency_get(int idx) { return idx >= 0 && idx < g_fre_cnt ? g_fre_ptrs[idx] : nullptr; }

int nav_frecency_score(int idx) { return idx >= 0 && idx < g_fre_cnt ? (int)g_fre_scores[idx] : 0; }

int nav_frecency_match(const char *substr, int *out_indices, int max_out)   /* indices of the entries containing substr (ASCII case-insensitive) */
{
    int n = 0;
    for (int i = 0; i < g_fre_cnt && n < max_out; i++)
        if (nav_ci_contains(g_fre_ptrs[i], substr)) out_indices[n++] = i;
    return n;
}

/* ---- lifecycle ---- */

void nav_state_init(const char *const *envp)             /* once: finds the data directory, creates it, loads both lists */
{
    if (g_data_ready) return;
    g_bm_cnt = 0;
    g_fre_cnt = 0;
    const char *v = nav_find_env(envp, "XDG_DATA_HOME=");
    if (v && *v) {
        (void)path_join(g_data_dir, v, "duop", PATH_MAX);
    } else {
        v = nav_find_env(envp, "HOME=");
        if (!v || !*v) return;
        char share[PATH_MAX] = "";
        (void)path_join(share, v, ".local/share", PATH_MAX);
        (void)path_join(g_data_dir, share, "duop", PATH_MAX);
    }
    nav_mkdir_p(g_data_dir);
    g_data_ready = 1;
    nav_bookmarks_load();
    nav_frecency_load();
}

void nav_state_cleanup(void)                             /* frees the bookmark and frecency strings */
{
    for (int i = 0; i < g_bm_cnt; i++) { mem_free(g_bm_ptrs[i]); g_bm_ptrs[i] = nullptr; }
    g_bm_cnt = 0;
    for (int i = 0; i < g_fre_cnt; i++) { mem_free(g_fre_ptrs[i]); g_fre_ptrs[i] = nullptr; }
    g_fre_cnt = 0;
}
