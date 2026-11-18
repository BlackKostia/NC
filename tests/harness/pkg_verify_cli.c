/* Freestanding harness: the frozen asm package hash list (pkg_verify_reference.s, x86_64, ref_ prefix) or src/fs/pkg_verify.c
 * (compiled into this unit, path in PKV_SRC). pkg_get_root (PKG_ROOT from the environment), pkm_safe_name and pkg_write_file are
 * stand-ins (they belong to pkg_manager.s / pkg_archive.s). argv[1] = ref | c. Script on stdin:
 *   V <name>                    pkg_verify
 *   A <file>...                 pkg_hashes_append of each file to one buffer (prefilled with n bytes by "A+<n>"), then the
 *                               buffer length and a hash of its content
 *   H <dir> <file>...           the same, then pkg_hashes_write(dir) */
#include "script_cli.h"
#include "duop_pkg.h"
#include "duop_pal.h"

static char g_root[PATH_MAX];

void pkg_get_root(char **envp, char *out, int cap)
{
    (void)envp;
    (void)str_copy(out, g_root, (size_t)cap);
}

int pkm_safe_name(const char *s)
{
    if (!*s || (s[0] == '.' && (!s[1] || (s[1] == '.' && !s[2])))) return 0;
    for (; *s; s++) if (*s == '/') return 0;
    return 1;
}

int pkg_write_file(const char *path, const void *buf, uint64_t len)
{
    intptr_t fd = os_openat(AT_FDCWD, path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    intptr_t w = sys_write_all((int)fd, buf, (size_t)len);
    (void)os_close((int)fd);
    return w < 0 ? -1 : 0;
}

#include PKV_SRC

#ifdef __x86_64__
extern int ref_pkg_verify(char **, const char *);
extern void ref_pkg_hashes_append(const char *, char *, uint64_t *);
extern int ref_pkg_hashes_write(const char *, const char *, uint64_t);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static char g_buf[PKG_LIST_CAP + 512];

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

static void cmd_append(char **f, int n, int first)
{
    uint64_t len = 0;
    for (size_t i = 0; i < sizeof g_buf; i++) g_buf[i] = '#';
    for (int i = first; i < n; i++) {
        if (f[i][0] == '+') { len = (uint64_t)num(f[i] + 1); continue; }
        CALLV(pkg_hashes_append, f[i], g_buf, &len);
    }
    int64_t beyond = 0;                                                /* bytes written past len (must stay 0) */
    for (size_t i = len < sizeof g_buf ? len : sizeof g_buf; i < sizeof g_buf; i++) beyond += g_buf[i] != '#';
    sc_put(" len="); sc_num((int64_t)len); sc_put(" beyond="); sc_num(beyond); sc_put(" buf=");
    if (len <= 65536) { char c = g_buf[len]; g_buf[len] = 0; sc_esc(g_buf); g_buf[len] = c; }
    else if (len <= sizeof g_buf) {                                     /* a long list: its last 300 bytes */
        char c = g_buf[len];
        g_buf[len] = 0;
        sc_put("..."); sc_esc(g_buf + len - 300);
        g_buf[len] = c;
    }
    if (first == 2) { sc_put(" w="); sc_num(CALL(pkg_hashes_write, f[1], g_buf, len)); }
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const char *r = env_getenv(envp, "PKG_ROOT");
    (void)str_copy(g_root, r ? r : "/nonexistent", PATH_MAX);
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[128];
        int n = sc_split(line, f, 128);
        if (!n) continue;
        switch (f[0][0]) {
        case 'V': sc_put("V "); sc_esc(n > 1 ? f[1] : ""); sc_put(" ="); sc_num(CALL(pkg_verify, envp, n > 1 ? f[1] : "")); break;
        case 'A': sc_put("A"); cmd_append(f, n, 1); break;
        case 'H': if (n < 2) continue; sc_put("H"); cmd_append(f, n, 2); break;
        default: continue;
        }
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
