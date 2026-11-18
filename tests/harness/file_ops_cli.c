/* Freestanding harness: the frozen asm small file operations and copy data path (file_ops_reference.s, x86_64, ref_ prefix) or
 * src/fs/file_ops.c (compiled into this unit, path in FO_SRC). argv = <ref|c> <base dir>: "@" at the start of a path argument stands
 * for the base dir, so the oracle and the C module work on identical trees. fs_progress_bytes / fs_progress_cancelled are
 * stand-ins that add up the reported bytes and request a cancel after a scripted number of calls. Script on stdin:
 *   E <errno>            fs_errno_message(-errno)
 *   K / T <path>         fs_mkdir / fs_touch;   R / Q <old> <new>  fs_rename / fs_rename_noreplace
 *   I <src> <dst>        path_is_same_or_descendant (no "@" expansion; "~" = empty string)
 *   D <src> <dst> <reg>  copy_data from an open src to a created / truncated dst (dst "/dev/full" as is)
 *   P <bytes> <dst>      copy_data from a pipe holding <bytes> bytes (is_regular 0)
 *   C <k>                the k-th fs_progress_cancelled call from now answers "cancel" (0: never)
 *   S <syscall> <errno>  (x86_64) seccomp: renameat2 with RENAME_NOREPLACE (n) / copy_file_range (c) fails with errno */
#include "script_cli.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_tui.h"

static uint64_t g_bytes, g_calls;
static int64_t g_cancel_in;

const LangStrings *i18n_get(void) { return &lang_en_table; }   /* the English table of build/i18n_en.c */
void fs_progress_bytes(uint64_t n) { g_bytes += n; }
int fs_progress_cancelled(void) { g_calls++; return g_cancel_in > 0 && --g_cancel_in == 0; }

#include FO_SRC

#ifdef __x86_64__
extern const char *ref_fs_errno_message(int);
extern intptr_t ref_fs_mkdir(const char *), ref_fs_touch(const char *);
extern intptr_t ref_fs_rename(const char *, const char *), ref_fs_rename_noreplace(const char *, const char *);
extern int ref_path_is_same_or_descendant(const char *, const char *);
extern intptr_t ref_copy_data(int, int, int);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))

static long sys5(long nr, long a, long b, long c, long d)
{
    long ret;
    register long r10 __asm__("r10") = d, r8 __asm__("r8") = 0, r9 __asm__("r9") = 0;   /* prctl wants the unused args 0 */
    __asm__ volatile("syscall" : "=a"(ret) : "a"(nr), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

/* one seccomp filter: syscall nr (and, for renameat2, flags == RENAME_NOREPLACE) -> ERRNO(err) */
static void cmd_seccomp(char which, uint32_t err)
{
    struct { uint16_t code; uint8_t jt, jf; uint32_t k; } prog[] = {
        {0x20, 0, 0, 0},                                       /* ld nr */
        {0x15, 0, 3, which == 'n' ? 316u : 326u},              /* jeq renameat2 / copy_file_range, else allow */
        {0x20, 0, 0, 48},                                      /* ld args[4] (renameat2 flags) */
        {0x15, which == 'n' ? 0 : 1, which == 'n' ? 1 : 0, 1}, /* renameat2: flags == 1 -> errno; copy_file_range: always */
        {0x06, 0, 0, 0x00050000u | err},                       /* ret ERRNO(err) */
        {0x06, 0, 0, 0x7fff0000u},                             /* ret ALLOW */
    };
    if (which != 'n') prog[3] = (typeof(prog[3])){0x05, 0, 0, 0};   /* ja +0: copy_file_range always fails */
    struct { uint16_t len; void *filter; } fprog = {6, prog};
    long a = sys5(157, 38, 1, 0, 0), b = sys5(317, 1, 0, (long)&fprog, 0);
    sc_put("S "); sc_num(a); sc_put(" "); sc_num(b);
}
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static char g_base[PATH_MAX], g_p1[PATH_MAX], g_p2[PATH_MAX];

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

static void progress(void) { sc_put(" bytes="); sc_num((int64_t)g_bytes); sc_put(" polls="); sc_num((int64_t)g_calls); g_bytes = g_calls = 0; }

static void cmd_copy(char **f)
{
    const char *dst = at(f[2], g_p2);
    intptr_t s = os_openat(AT_FDCWD, at(f[1], g_p1), O_RDONLY | O_CLOEXEC, 0);
    intptr_t d = os_openat(AT_FDCWD, dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (s < 0 || d < 0) { sc_put("D open "); sc_num(s < 0 ? s : d); if (s >= 0) (void)os_close((int)s); if (d >= 0) (void)os_close((int)d); return; }
    intptr_t r = CALL(copy_data, (int)s, (int)d, (int)num(f[3]));
    (void)os_close((int)s);
    (void)os_close((int)d);
    sc_put("D r="); sc_num(r); progress();
}

static void cmd_pipe(char **f)
{
    int p[2];
    if (os_pipe2(p, O_CLOEXEC) < 0) return;
    static uint8_t data[60000];
    size_t n = (size_t)num(f[1]);
    if (n > sizeof data) n = sizeof data;
    for (size_t i = 0; i < n; i++) data[i] = (uint8_t)(i * 7 + 3);
    (void)sys_write_all(p[1], data, n);
    (void)os_close(p[1]);
    intptr_t d = os_openat(AT_FDCWD, at(f[2], g_p2), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    intptr_t r = d < 0 ? d : CALL(copy_data, p[0], (int)d, 0);
    if (d >= 0) (void)os_close((int)d);
    (void)os_close(p[0]);
    sc_put("P r="); sc_num(r); progress();
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 3) return 2;
    g_ref = argv[1][0] == 'r';
    (void)str_copy(g_base, argv[2], PATH_MAX);
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[6];
        int n = sc_split(line, f, 6);
        if (!n) continue;
        switch (f[0][0]) {
        case 'E': sc_put("E "); sc_esc(CALL(fs_errno_message, -(int)num(f[1]))); break;
        case 'K': sc_put("K "); sc_num(CALL(fs_mkdir, at(f[1], g_p1))); break;
        case 'T': sc_put("T "); sc_num(CALL(fs_touch, at(f[1], g_p1))); break;
        case 'R': if (n < 3) continue; sc_put("R "); sc_num(CALL(fs_rename, at(f[1], g_p1), at(f[2], g_p2))); break;
        case 'Q': if (n < 3) continue; sc_put("Q "); sc_num(CALL(fs_rename_noreplace, at(f[1], g_p1), at(f[2], g_p2))); break;
        case 'I': {
            if (n < 3) continue;
            const char *a = f[1][0] == '~' ? "" : f[1], *b = f[2][0] == '~' ? "" : f[2];
            sc_put("I "); sc_num(CALL(path_is_same_or_descendant, a, b));
            break;
        }
        case 'D': if (n < 4) continue; cmd_copy(f); break;
        case 'P': if (n < 3) continue; cmd_pipe(f); break;
        case 'C': g_cancel_in = num(f[1]); continue;
#ifdef __x86_64__
        case 'S': if (n < 3) continue; cmd_seccomp(f[1][0], (uint32_t)num(f[2])); break;
#endif
        default: continue;
        }
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
