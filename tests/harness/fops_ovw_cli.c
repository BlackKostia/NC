/* Freestanding harness: frozen asm fo_open_overwrite / fo_overwrite_open / fo_overwrite_commit (x86_64, ref_ prefix) next to
 * src/fs/file_ops_overwrite.c. Directory A is handled by the oracle, directory B by the C module (identical trees), so both
 * counters of the temp-name sequence advance in step. Script on stdin:
 *   O <name> <dst_mode octal> <new_mode octal> [N]   fo_open_overwrite, write a payload, fsync, commit when a temp file was used
 *                                                     (N: leave the temp file uncommitted)
 *   W <name> <new_mode octal>                         fo_overwrite_open on its own (the fd is closed, the temp file stays)
 *   X <k>                                             pre-create the next k temp names (sequence numbers) in A and B
 *   M <tmp> <name>                                    fo_overwrite_commit on its own
 *   P                                                 (x86_64) seccomp: every openat with O_EXCL fails with -EPERM from now on
 * Each command prints "<cmd> ref=<ret>/<used> c=<ret>/<used> <same|DIFF-...> tmp=<name or ->"; on aarch64 there is no oracle (ref=-). */
#include "script_cli.h"
#include "duop_fs.h"
#include "duop_pal.h"

#ifdef __x86_64__
#define HAVE_REF 1
#define REF_PRESENT true
typedef struct { intptr_t fd; uint64_t used; } ovw_res;
extern ovw_res ovw_ref_open(int, const char *, uint32_t, uint32_t, char *);
extern intptr_t ref_fo_overwrite_open(int, const char *, uint32_t, char *);
extern intptr_t ref_fo_overwrite_commit(int, const char *, const char *);
#endif

#ifndef REF_PRESENT
#define REF_PRESENT false
#endif

static char g_ra[PATH_MAX], g_rb[PATH_MAX];
static uint32_t g_seq;                       /* last sequence number seen in a returned temp name */

static int sc_split(char *line, char **f, int max)      /* blank-separated fields, in place */
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

static uint32_t dec(const char *s) { uint32_t v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (uint32_t)(*s++ - '0'); return v; }

static uint32_t oct(const char *s) { uint32_t v = 0; while (*s >= '0' && *s <= '7') v = v * 8 + (uint32_t)(*s++ - '0'); return v; }

static void note_seq(const char *tmp)        /* ".duop-ovw.<pid>.<seq>" at the end of the temp path */
{
    size_t n = str_len(tmp);
    if (n < 9 || tmp[n - 9] != '.') return;
    uint32_t v = 0;
    for (size_t i = n - 8; i < n; i++) v = v * 16 + (uint32_t)(tmp[i] <= '9' ? tmp[i] - '0' : tmp[i] - 'a' + 10);
    g_seq = v;
}

static void payload(int fd, const char *name)
{
    if (fd < 0) return;
    (void)os_write(fd, "payload:", 8);
    (void)os_write(fd, name, str_len(name));
    (void)os_fsync(fd);
    (void)os_close(fd);
}

static void put_res(const char *tag, bool have, intptr_t r, uint64_t used)
{
    sc_put(tag);
    if (!have) { sc_put("-/-"); return; }
    sc_num(r); sc_put("/"); sc_num((int64_t)used);
}

static bool same_buf(void)
{
    for (size_t i = 0; i < sizeof g_ra; i++) if (g_ra[i] != g_rb[i]) return false;
    return true;
}

static void cmd_open(int da, int db, char *name, uint32_t dm, uint32_t nm, bool commit)
{
    for (size_t i = 0; i < sizeof g_ra; i++) g_ra[i] = g_rb[i] = (char)0xA5;
    intptr_t ra = 0; uint64_t ua = 0;
#ifdef HAVE_REF
    ovw_res r = ovw_ref_open(da, name, dm, nm, g_ra);
    ra = r.fd; ua = r.used;
    if (ra >= 0) payload((int)ra, name);              /* close the oracle's fd first: both runs then see the same fd numbers */
#else
    (void)da;
#endif
    FoOpenResult c = fo_open_overwrite(db, name, dm, nm, g_rb);
    bool same = ra == c.fd && ua == c.used && same_buf();
#ifndef HAVE_REF
    same = true;
#endif
    sc_put("O "); sc_put(name[0] ? name : "-"); sc_put(" ");
    put_res("ref=", REF_PRESENT, ra, ua); put_res(" c=", true, c.fd, c.used);
    if (c.fd >= 0) { note_seq(g_rb); payload((int)c.fd, name); }
    if (c.used && commit) {
        intptr_t cb = fo_overwrite_commit(db, g_rb, name);
        intptr_t ca = 0;
#ifdef HAVE_REF
        ca = ref_fo_overwrite_commit(da, g_ra, name);
#else
        ca = cb;
#endif
        same = same && ca == cb;
        sc_put(" commit="); sc_num(cb);
    }
    sc_put(same ? " same" : " DIFF"); sc_put(" tmp="); sc_put(c.used ? g_rb : "-"); sc_put("\n");
}

static void cmd_plain(int da, int db, char *name, uint32_t nm)                    /* W: fo_overwrite_open alone */
{
    for (size_t i = 0; i < sizeof g_ra; i++) g_ra[i] = g_rb[i] = (char)0xA5;
    intptr_t ra = 0;
#ifdef HAVE_REF
    ra = ref_fo_overwrite_open(da, name, nm, g_ra);
#else
    (void)da;
#endif
#ifdef HAVE_REF
    if (ra >= 0) (void)os_close((int)ra);
#endif
    intptr_t rb = fo_overwrite_open(db, name, nm, g_rb);
    bool same = true;
#ifdef HAVE_REF
    same = ra == rb && same_buf();
#endif
    sc_put("W "); sc_put(name); sc_put(" "); put_res("ref=", REF_PRESENT, ra, 0); put_res(" c=", true, rb, 0);
    if (rb >= 0) { note_seq(g_rb); (void)os_close((int)rb); }
    sc_put(same ? " same" : " DIFF"); sc_put(" tmp="); sc_put(rb >= 0 ? g_rb : "-"); sc_put("\n");
}

static void cmd_commit(int da, int db, char *tmp, char *name)                   /* M: fo_overwrite_commit alone */
{
    intptr_t ra = 0, rb = fo_overwrite_commit(db, tmp, name);
#ifdef HAVE_REF
    ra = ref_fo_overwrite_commit(da, tmp, name);
#else
    (void)da; ra = rb;
#endif
    sc_put("M "); sc_put(tmp); sc_put(" "); put_res("ref=", REF_PRESENT, ra, 0); put_res(" c=", true, rb, 0); sc_put(ra == rb ? " same\n" : " DIFF\n");
}

#ifdef HAVE_REF
static long sys5(long nr, long a, long b, long c, long d)
{
    long ret;
    register long r10 __asm__("r10") = d;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(nr), "D"(a), "S"(b), "d"(c), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}

static void cmd_eperm(void)                                                     /* P: an EPERM source no unprivileged test can create */
{
    struct { uint16_t code; uint8_t jt, jf; uint32_t k; } prog[] = {
        {0x20, 0, 0, 0},                 /* ld  nr                      */
        {0x15, 0, 3, 257},               /* jeq openat, else allow      */
        {0x20, 0, 0, 32},                /* ld  args[2] (flags)         */
        {0x45, 0, 1, 0x80},              /* jset O_EXCL, else allow     */
        {0x06, 0, 0, 0x00050000u | 1},   /* ret ERRNO(EPERM)            */
        {0x06, 0, 0, 0x7fff0000u},       /* ret ALLOW                   */
    };
    struct { uint16_t len; void *filter; } fprog = {6, prog};
    long a = sys5(157, 38, 1, 0, 0), b = sys5(317, 1, 0, (long)&fprog, 0);       /* PR_SET_NO_NEW_PRIVS, seccomp(SET_MODE_FILTER) */
    sc_put("P "); sc_num(a); sc_put(" "); sc_num(b); sc_put("\n");
}
#endif

static void cmd_collide(int da, int db, uint32_t k)                             /* X: occupy the next k sequence numbers */
{
    char name[48];
    uint32_t pid = (uint32_t)os_getpid();
    for (uint32_t i = 1; i <= k; i++) {
        str_copy(name, ".duop-ovw.", sizeof name);
        (void)u64_to_hex(pid, name + 10, 8);
        name[18] = '.';
        (void)u64_to_hex(g_seq + i, name + 19, 8);
        name[27] = 0;
        for (int d = 0; d < 2; d++) {
            intptr_t fd = os_openat(d ? db : da, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
            if (fd >= 0) (void)os_close((int)fd);
        }
    }
    sc_put("X "); sc_num(k); sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 3) return 2;
    int da = (int)os_openat(AT_FDCWD, argv[1], O_RDONLY | O_DIRECTORY, 0), db = (int)os_openat(AT_FDCWD, argv[2], O_RDONLY | O_DIRECTORY, 0);
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[6];
        int n = sc_split(line, f, 6);
        if (n >= 4 && f[0][0] == 'O') cmd_open(da, db, f[1][0] == '-' && !f[1][1] ? (char *)"" : f[1], oct(f[2]), oct(f[3]), !(n >= 5 && f[4][0] == 'N'));
        else if (n >= 3 && f[0][0] == 'W') cmd_plain(da, db, f[1], oct(f[2]));
#ifdef HAVE_REF
        else if (f[0][0] == 'P') cmd_eperm();
#endif
        else if (n >= 2 && f[0][0] == 'X') cmd_collide(da, db, dec(f[1]));
        else if (n >= 3 && f[0][0] == 'M') cmd_commit(da, db, f[1], f[2]);
    }
    sc_flush();
    return 0;
}
