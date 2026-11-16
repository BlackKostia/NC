/* tools/pal_selftest/pal_selftest.c - freestanding C23 self-test of the PAL ABI (Етап 1b).
 * Runs on any target (native x86_64, qemu-aarch64, native arm64): `./pal_selftest` prints
 * "PAL SELFTEST PASSED n/n" and exits 0, or lists every failed check and exits 1.
 * Needs only pal_start.s + pal_*.s + mem.c: no libc, no allocator.
 */
#include "duop_abi.h"

enum { O_RDONLY_ = 0, O_WRONLY_ = 1, O_RDWR_ = 2, O_CREAT_ = 0x40, O_EXCL_ = 0x80, O_DIRECTORY_ARM = 0x4000 };
#define AT_FDCWD_ (-100)

static int g_total, g_fail;
static char g_dir[64];

static size_t cstr_len(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
static void out(const char *s) { (void)os_write(1, s, cstr_len(s)); }
static void out_num(int64_t v)
{
    char b[24]; int i = 24; uint64_t u = v < 0 ? (uint64_t)-v : (uint64_t)v;
    do { b[--i] = (char)('0' + u % 10); u /= 10; } while (u);
    if (v < 0) b[--i] = '-';
    (void)os_write(1, b + i, (size_t)(24 - i));
}
static void check(bool ok, const char *what, int64_t got)
{
    g_total++;
    if (ok) return;
    g_fail++;
    out("FAIL: "); out(what); out(" (got "); out_num(got); out(")\n");
}
static void path_cat(char *dst, const char *a, const char *b)
{
    size_t n = 0;
    while (*a) dst[n++] = *a++;
    dst[n++] = '/';
    while (*b) dst[n++] = *b++;
    dst[n] = 0;
}
static void make_dir_name(void)
{
    const char *p = "/tmp/duop_pal_st_";
    size_t n = 0;
    while (*p) g_dir[n++] = *p++;
    char d[16]; int k = 0; uint64_t pid = (uint64_t)os_getpid();
    do { d[k++] = (char)('0' + pid % 10); pid /= 10; } while (pid);
    while (k) g_dir[n++] = d[--k];
    g_dir[n] = 0;
}
static intptr_t write_file(const char *name, const char *data, size_t n)
{
    char p[128]; path_cat(p, g_dir, name);
    intptr_t fd = os_openat(AT_FDCWD_, p, O_WRONLY_ | O_CREAT_ | O_EXCL_, 0644);
    if (os_is_err(fd)) return fd;
    intptr_t w = os_write((int)fd, data, n);
    (void)os_close((int)fd);
    return w;
}

static void test_files(void)
{
    char p[128], q[128];
    check(os_mkdirat(AT_FDCWD_, g_dir, 0755) == 0, "mkdirat tmp dir", 0);
    check(write_file("a.txt", "hello", 5) == 5, "openat(O_EXCL)+write", 0);
    path_cat(p, g_dir, "a.txt");
    intptr_t dupe = os_openat(AT_FDCWD_, p, O_WRONLY_ | O_CREAT_ | O_EXCL_, 0644);
    check(dupe == -17, "O_EXCL on existing file -> -EEXIST", dupe);
    FileStat st = {0};
    check(os_statat(AT_FDCWD_, p, &st, 1) == 0 && st.size == 5, "statat size==5", (int64_t)st.size);
    check((st.mode & 0170000) == 0100000, "statat mode is regular file", st.mode);
    check(st.nlink == 1 && st.ino != 0 && st.mtime > 1000000000, "statat nlink/ino/mtime", (int64_t)st.nlink);
    check(os_statat(AT_FDCWD_, "/nonexistent/duop", &st, 1) == -2, "statat missing -> -ENOENT", 0);
    path_cat(q, g_dir, "ln");
    check(os_symlinkat("a.txt", AT_FDCWD_, q) == 0, "symlinkat", 0);
    check(os_statat(AT_FDCWD_, q, &st, 0) == 0 && (st.mode & 0170000) == 0120000, "statat(nofollow) sees symlink", st.mode);
    intptr_t nf = os_openat(AT_FDCWD_, q, O_RDONLY_ | 0x8000 /* O_NOFOLLOW on arm/arm64 */, 0);
#if defined(__x86_64__)
    nf = os_openat(AT_FDCWD_, q, O_RDONLY_ | 0x20000, 0);
#endif
    check(nf == -40, "O_NOFOLLOW on symlink -> -ELOOP (regression: arm64 O_DIRECT)", nf);
    char buf[16];
    intptr_t n = os_readlinkat(AT_FDCWD_, q, buf, sizeof buf);
    check(n == 5 && buf[0] == 'a', "readlinkat", n);
    char r[128]; path_cat(r, g_dir, "b.txt");
    check(os_renameat2(AT_FDCWD_, p, AT_FDCWD_, r, 1) == 0, "renameat2(NOREPLACE) to free name", 0);
    check(write_file("a.txt", "x", 1) == 1, "recreate a.txt", 0);
    intptr_t re = os_renameat2(AT_FDCWD_, p, AT_FDCWD_, r, 1);
    check(re == -17, "renameat2(NOREPLACE) over existing -> -EEXIST", re);
    check(os_fstat(0, &st) < 0 || st.mode != 0, "fstat(stdin) answers", 0);
}

static void test_dir(void)
{
    intptr_t d = os_openat(AT_FDCWD_, g_dir, O_RDONLY_
#if defined(__x86_64__)
        | 0x10000
#else
        | O_DIRECTORY_ARM
#endif
        , 0);
    check(!os_is_err(d), "open dir with O_DIRECTORY", d);
    if (os_is_err(d)) return;
    static char buf[4096] __attribute__((aligned(8)));
    intptr_t got = os_dir_read((int)d, buf, sizeof buf);
    check(got > 0, "getdents64 returns entries", got);
    size_t pos = 0; int seen_a = 0, seen_b = 0, seen_ln = 0, seen_dots = 0, total = 0;
    uint8_t type;
    for (const char *name; got > 0 && (name = os_dir_next_ex(buf, (size_t)got, &pos, &type)); total++) {
        if (name[0] == 'a' && !name[1]) seen_a = 1;
        else if (name[0] == 'b' && name[1] == '.') seen_b = 1;
        else if (name[0] == 'l' && name[1] == 'n' && !name[2]) { seen_ln = 1; check(type == 10, "d_type of symlink == DT_LNK", type); }
        else if (name[0] == '.') seen_dots++;
    }
    check(seen_a == 0 && seen_b && seen_ln && seen_dots == 2 && total == 5, "dir entries (., .., a.txt, b.txt, ln)", total);
    (void)os_close((int)d);
}

static void test_pipe_poll_fork(void)
{
    int fds[2];
    check(os_pipe_cloexec(fds) == 0, "pipe2(O_CLOEXEC)", 0);
    check(os_poll_in(fds[0], 0) == 0, "poll_in empty pipe -> 0", 0);
    check(os_write(fds[1], "z", 1) == 1, "write pipe", 0);
    check(os_poll_in(fds[0], 100) > 0, "poll_in readable -> >0", 0);
    int two[2] = {fds[0], -1};
    check(os_poll_many(two, 1, 0) == 1, "poll_many bitmask", 0);
    check(os_poll_in2(fds[0], -1, 0) == 1, "poll_in2 bit0", 0);
    check(os_set_nonblock(fds[0]) == 0, "set_nonblock", 0);
    char c;
    check(os_read(fds[0], &c, 1) == 1 && c == 'z', "read pipe", 0);
    check(os_read(fds[0], &c, 1) == -11, "read drained nonblocking pipe -> -EAGAIN", 0);
    intptr_t pid = os_fork();
    if (pid == 0) os_exit(7);
    int status = 0;
    intptr_t w = os_wait4((int)pid, &status, 0, nullptr);
    check(pid > 0 && w == pid && status == (7 << 8), "fork/exit(7)/wait4 status", status);
    (void)os_close(fds[0]); (void)os_close(fds[1]);
}

static void test_mem_time(void)
{
    intptr_t m = os_mmap(nullptr, 8192, 3, 0x22, -1, 0);
    check(!os_is_err(m), "mmap anon", m);
    if (os_is_err(m)) return;
    uint8_t *p = (uint8_t *)m;
    p[0] = 1; p[8191] = 2;
    uint8_t *q = os_mem_remap(p, 8192, 16384);
    check(!os_is_err((intptr_t)q) && q[0] == 1 && q[8191] == 2, "mremap keeps contents", (intptr_t)q);
    for (int i = 0; i < 64; i++) q[100 + i] = (uint8_t)i;
    check(os_mem_find_byte(q + 100, 64, 40) == 40, "mem_find_byte", 0);
    check(os_mem_find_byte(q + 100, 64, 200) == 64, "mem_find_byte absent -> len", 0);
    check(os_mem_count_byte(q + 100, 64, 5) == 1, "mem_count_byte", 0);
    static uint8_t a[64] __attribute__((aligned(16))), b[64] __attribute__((aligned(16)));
    check(os_mem_mismatch16(a, b, 4) == 4, "mem_mismatch16 equal -> n16", 0);
    b[37] = 1;
    check(os_mem_mismatch16(a, b, 4) == 2, "mem_mismatch16 differing block index", 0);
    os_munmap(q, 16384);
    int64_t t0 = os_clock_ms(), t1 = os_clock_ms();
    check(t0 > 0 && t1 >= t0, "clock_ms monotonic", t0);
}

extern void os_mem_copy_fast(void *d, const void *s, size_t n);
extern void os_mem_move_fast(void *d, const void *s, size_t n);
extern void os_mem_set_fast(void *d, int c, size_t n);
extern int os_mem_cmp_fast(const void *a, const void *b, size_t n);
extern size_t os_str_len_fast(const char *s);
extern int os_str_contains_ci_fast(const char *hay, const char *needle_lc, size_t nlen);

static void test_simd(void)
{
    static uint8_t a[100] __attribute__((aligned(16))), b[100] __attribute__((aligned(16)));
    for (int i = 0; i < 100; i++) a[i] = (uint8_t)(i * 7 + 1);
    os_mem_copy_fast(b, a, 100);
    check(os_mem_cmp_fast(a, b, 100) == 0, "mem_copy_fast + mem_cmp_fast equal", 0);
    b[63] ^= 1;
    check(os_mem_cmp_fast(a, b, 100) != 0, "mem_cmp_fast detects difference", 0);
    check((os_mem_cmp_fast(a, b, 100) > 0) == (a[63] > b[63]), "mem_cmp_fast sign follows the first differing byte", 0);
    os_mem_move_fast(a + 3, a, 90);
    check(a[3] == 1 && a[4] == 8 && a[92] == (uint8_t)(89 * 7 + 1), "mem_move_fast overlapping (dst > src)", a[92]);
    os_mem_move_fast(a, a + 3, 90);
    check(a[0] == 1 && a[1] == 8, "mem_move_fast overlapping (dst < src)", a[1]);
    os_mem_set_fast(b + 1, 0x5a, 37);
    check(b[0] == 0x01 && b[1] == 0x5a && b[37] == 0x5a && b[38] != 0x5a, "mem_set_fast bounds", b[38]);
    check(os_str_len_fast("") == 0 && os_str_len_fast("hello") == 5, "str_len_fast", 0);
    static const char long_s[] = "0123456789abcdef0123456789abcdef0123456789abcdef!";
    check(os_str_len_fast(long_s) == 49, "str_len_fast across 16-byte blocks", 0);
    check(os_str_contains_ci_fast("Hello World", "world", 5) == 1, "contains_ci finds folded needle", 0);
    check(os_str_contains_ci_fast("Hello World", "worlds", 6) == 0, "contains_ci rejects longer needle", 0);
    check(os_str_contains_ci_fast("Hello", "", 0) == 1, "contains_ci empty needle -> 1", 0);
    check(os_str_contains_ci_fast("A@B", "a`b", 3) == 0, "contains_ci does not fold non-letters ('@' != '`')", 0);
    check(os_str_contains_ci_fast("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxNeedle", "needle", 6) == 1, "contains_ci match beyond first block", 0);
}

static void test_signals_term(void)
{
    os_signals_worker_mode();
    check(os_kill((int)os_getpid(), 15) == 0, "SIGTERM handled by no-op handler (restorer works)", 0);
    check(os_kill((int)os_getpid(), 28) == 0, "SIGWINCH ignored", 0);
    int c = 99, r = 99;
    os_get_winsize(&c, &r);
    check(c >= 0 && r >= 0, "get_winsize tolerates non-tty", c);
    os_term_save_and_raw();
    check(os_term_restore() == 0, "term_restore without raw mode is a no-op", 0);
}

static void test_watch_copy(void)
{
    int w = os_watch_init();
    check(w >= 0, "inotify init", w);
    if (w < 0) return;
    int wd = os_watch_add(w, g_dir, 0x100 /* PAL_IN_CREATE */);
    check(wd > 0, "inotify add watch", wd);
    check(write_file("c.txt", "12345678", 8) == 8, "create c.txt", 0);
    check(os_poll_in(w, 200) > 0, "watch fd readable after create", 0);
    char ev[512] __attribute__((aligned(8)));
    intptr_t n = os_watch_read(w, ev, sizeof ev);
    size_t pos = 0; int ewd = 0; uint32_t mask = 0;
    check(n > 0 && os_watch_next(ev, (size_t)n, &pos, &ewd, &mask) == 1 && ewd == wd && (mask & 0x100), "watch_next IN_CREATE", n);
    check(os_watch_rm(w, wd) == 0, "inotify rm watch", 0);
    (void)os_close(w);
    char p[128], q[128]; path_cat(p, g_dir, "c.txt"); path_cat(q, g_dir, "d.txt");
    int in = (int)os_openat(AT_FDCWD_, p, O_RDONLY_, 0);
    int dst = (int)os_openat(AT_FDCWD_, q, O_RDWR_ | O_CREAT_, 0644);
    intptr_t cp = os_copy_file_range(in, dst, 8);
    check(cp == 8, "copy_file_range 8 bytes", cp);
    void *map = os_mmap_file_ro(dst, 8);
    check(map && ((const char *)map)[7] == '8', "mmap_file_ro contents", 0);
    os_munmap(map, 8);
    (void)os_close(in); (void)os_close(dst);
}

static void cleanup(void)
{
    static const char *names[] = {"a.txt", "b.txt", "c.txt", "d.txt", "ln"};
    char p[128];
    for (size_t i = 0; i < 5; i++) { path_cat(p, g_dir, names[i]); (void)os_unlinkat(AT_FDCWD_, p, 0); }
    check(os_unlinkat(AT_FDCWD_, g_dir, 0x200) == 0, "unlinkat(AT_REMOVEDIR) tmp dir", 0);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)envp; (void)auxv;
    make_dir_name();
    test_files();
    test_dir();
    test_pipe_poll_fork();
    test_mem_time();
    test_simd();
    test_signals_term();
    test_watch_copy();
    cleanup();
    if (g_fail) { out("PAL SELFTEST FAILED "); out_num(g_fail); out("/"); out_num(g_total); out("\n"); return 1; }
    out("PAL SELFTEST PASSED "); out_num(g_total); out("/"); out_num(g_total); out("\n");
    return 0;
}
