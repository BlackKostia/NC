/* Freestanding harness: frozen asm directory watcher (ref_ prefix) next to src/fs/dir_watch.c. One implementation per process,
 * tab-separated script on stdin; every call prints its result:
 *   INIT  FD  SET <slot> <path>  POLL  CLEAN                       the watcher
 *   W <path> create / append    R <path> unlink    V <old> <new> rename    M <path> mkdir    D <path> rmdir
 *   H <path> chmod 0600         MANY <dir> <n> create n files       (file-system edits made between the calls) */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

extern int ref_dirwatch_init(void);
extern int ref_dirwatch_fd(void);
extern void ref_dirwatch_set(int, const char *);
extern uint32_t ref_dirwatch_poll(void);
extern void ref_dirwatch_cleanup(void);

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

static char *field(char **p)
{
    char *s = *p;
    while (**p && **p != '\t') (*p)++;
    if (**p) *(*p)++ = 0;
    return s;
}

static int to_int(const char *s)
{
    int v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return v;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    bool ref = !str_cmp(argv[1], "ref");
    static char in[1 << 20];
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
        if (!str_cmp(op, "INIT")) num(ref ? ref_dirwatch_init() : dirwatch_init());
        else if (!str_cmp(op, "FD")) num((ref ? ref_dirwatch_fd() : dirwatch_fd()) >= 0);      /* the number itself differs between runs */
        else if (!str_cmp(op, "SET")) { if (ref) ref_dirwatch_set(to_int(a), b); else dirwatch_set(to_int(a), b); put("set"); }
        else if (!str_cmp(op, "POLL")) num(ref ? ref_dirwatch_poll() : dirwatch_poll());
        else if (!str_cmp(op, "CLEAN")) { if (ref) ref_dirwatch_cleanup(); else dirwatch_cleanup(); put("clean"); }
        else if (!str_cmp(op, "W")) { intptr_t f = os_openat(AT_FDCWD, a, O_WRONLY | O_CREAT | O_APPEND, 0644); if (f >= 0) { (void)os_write((int)f, "x", 1); os_close((int)f); } put("w"); }
        else if (!str_cmp(op, "R")) { num(os_unlinkat(AT_FDCWD, a, 0)); }
        else if (!str_cmp(op, "V")) { num(os_renameat2(AT_FDCWD, a, AT_FDCWD, b, 0)); }
        else if (!str_cmp(op, "M")) { num(os_mkdirat(AT_FDCWD, a, 0755)); }
        else if (!str_cmp(op, "D")) { num(os_unlinkat(AT_FDCWD, a, AT_REMOVEDIR)); }
        else if (!str_cmp(op, "H")) { num(os_fchmodat(AT_FDCWD, a, 0600)); }
        else if (!str_cmp(op, "MANY")) {
            int cnt = to_int(b);
            char path[PATH_MAX];
            for (int i = 0; i < cnt; i++) {
                str_copy(path, a, PATH_MAX);
                str_cat(path, "/f", PATH_MAX);
                u64_to_dec((uint64_t)i, path + str_len(path));
                intptr_t f = os_openat(AT_FDCWD, path, O_WRONLY | O_CREAT, 0644);
                if (f >= 0) os_close((int)f);
            }
            put("many");
        }
        put("\n");
        line = next;
    }
    flush();
    return 0;
}
