/* Freestanding harness: frozen asm navigation state (ref_ prefix) next to src/fs/nav_state.c and nav_persist.c. One
 * implementation per process, driven by a tab-separated script on stdin:
 *   E <NAME=value>  add to envp     INIT       nav_state_init          CLEAN      nav_state_cleanup
 *   BA <path> BR <idx> BC BG <idx>  bookmarks  FR <path> FC FG <idx> FS <idx> FM <substr> <max>   frecency
 *   TA <path|->     nav_tabs_alloc  TF <count> nav_tabs_free           HP <tab> <path>  HB <tab>  HF <tab>  HD <tab>   history
 *   CI <hay> <needle>  nav_ci_contains     (every call prints its result; HD prints pos, len and the paths) */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

extern char *ref_nav_strdup(const char *);
extern int ref_nav_ci_contains(const char *, const char *);
extern NavTab *ref_nav_tabs_alloc(const char *);
extern void ref_nav_tabs_free(NavTab *, int);
extern void ref_nav_hist_push(NavTab *, const char *);
extern const char *ref_nav_hist_back(NavTab *);
extern const char *ref_nav_hist_fwd(NavTab *);
extern void ref_nav_state_init(const char *const *);
extern void ref_nav_state_cleanup(void);
extern int ref_nav_bookmarks_count(void);
extern const char *ref_nav_bookmarks_get(int);
extern int ref_nav_bookmarks_add(const char *);
extern void ref_nav_bookmarks_remove(int);
extern void ref_nav_frecency_record(const char *);
extern int ref_nav_frecency_count(void);
extern const char *ref_nav_frecency_get(int);
extern int ref_nav_frecency_score(int);
extern int ref_nav_frecency_match(const char *, int *, int);

static char g_out[1 << 16];
static size_t g_n;
static void flush(void) { (void)os_write(1, g_out, g_n); g_n = 0; }
static void put(const char *s) { while (*s) { if (g_n >= sizeof g_out - 8) flush(); g_out[g_n++] = *s++; } }
static void num(int64_t v)
{
    char t[24];
    if (v < 0) { put("-"); v = -v; }
    t[u64_to_dec((uint64_t)v, t)] = 0;
    put(t);
}
static void str(const char *s) { if (s) { put("["); put(s); put("]"); } else put("(null)"); }

static char *field(char **p)
{
    char *s = *p;
    while (**p && **p != '\t') (*p)++;
    if (**p) *(*p)++ = 0;
    return s;
}

static int to_int(const char *s)
{
    bool neg = *s == '-';
    int v = 0;
    for (s += neg; *s >= '0' && *s <= '9'; s++) v = v * 10 + (*s - '0');
    return neg ? -v : v;
}

#define CALL(r, f, ...) ((r) ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(r, f, ...) do { if (r) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    bool r = !str_cmp(argv[1], "ref");
    static char in[1 << 21];
    static const char *env[16];
    int env_n = 0;
    NavTab *tabs = nullptr;
    size_t n = 0;
    intptr_t rd;
    while (n < sizeof in - 1 && (rd = os_read(0, in + n, sizeof in - 1 - n)) > 0) n += (size_t)rd;
    in[n] = 0;
    for (char *line = in; *line;) {
        char *eol = line;
        while (*eol && *eol != '\n') eol++;
        char *next = *eol ? eol + 1 : eol;
        *eol = 0;
        char *op = line, *p = line;
        while (*p && *p != '\t') p++;
        if (*p) *p++ = 0;
        char *a = field(&p), *b = field(&p);
        if (!str_cmp(op, "E")) { if (env_n < 14) { env[env_n++] = a; env[env_n] = nullptr; } put("env"); }
        else if (!str_cmp(op, "INIT")) { CALLV(r, nav_state_init, env_n ? env : nullptr); put("init"); }
        else if (!str_cmp(op, "CLEAN")) { CALLV(r, nav_state_cleanup); put("clean"); }
        else if (!str_cmp(op, "BA")) num(CALL(r, nav_bookmarks_add, a));
        else if (!str_cmp(op, "BR")) { CALLV(r, nav_bookmarks_remove, to_int(a)); put("removed"); }
        else if (!str_cmp(op, "BC")) num(CALL(r, nav_bookmarks_count));
        else if (!str_cmp(op, "BG")) str(CALL(r, nav_bookmarks_get, to_int(a)));
        else if (!str_cmp(op, "FR")) { CALLV(r, nav_frecency_record, a); put("recorded"); }
        else if (!str_cmp(op, "FC")) num(CALL(r, nav_frecency_count));
        else if (!str_cmp(op, "FG")) str(CALL(r, nav_frecency_get, to_int(a)));
        else if (!str_cmp(op, "FS")) num(CALL(r, nav_frecency_score, to_int(a)));
        else if (!str_cmp(op, "FM")) {
            int out[NAV_FRE_MAX + 4], k = CALL(r, nav_frecency_match, a, out, to_int(b));
            num(k);
            for (int i = 0; i < k; i++) { put(" "); num(out[i]); }
        }
        else if (!str_cmp(op, "CI")) num(CALL(r, nav_ci_contains, a, b));
        else if (!str_cmp(op, "TA")) { tabs = CALL(r, nav_tabs_alloc, str_cmp(a, "-") ? a : nullptr); put(tabs ? "tabs" : "nomem"); }
        else if (!str_cmp(op, "TF")) { CALLV(r, nav_tabs_free, tabs, to_int(a)); tabs = nullptr; put("freed"); }
        else if (tabs && !str_cmp(op, "HP")) { CALLV(r, nav_hist_push, &tabs[to_int(a) & 7], b); put("pushed"); }
        else if (tabs && !str_cmp(op, "HB")) str(CALL(r, nav_hist_back, &tabs[to_int(a) & 7]));
        else if (tabs && !str_cmp(op, "HF")) str(CALL(r, nav_hist_fwd, &tabs[to_int(a) & 7]));
        else if (tabs && !str_cmp(op, "HD")) {
            NavTab *t = &tabs[to_int(a) & 7];
            put("path="); put(t->path); put(" pos="); num(t->hist_pos); put(" len="); num(t->hist_len); put(" cur="); num(t->cursor);
            for (int i = 0; i < t->hist_len; i++) { put(" "); str(t->hist[i]); }
        }
        put("\n");
        line = next;
    }
    flush();
    return 0;
}
