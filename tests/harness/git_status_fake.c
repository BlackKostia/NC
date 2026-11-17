/* A stand-in git for tests/test_c_git_status.py (found first on PATH). argv[5] is the directory after "-C"; it appends its argv,
 * its environment and what fds 0 / 2 are (readlink of /proc/self/fd/N) to <dir>/.fake_log, then acts on the first byte of
 * <dir>/.fake_mode:  o  print <dir>/.fake_out, exit 0     f  print it, exit 1     h  hang until killed
 *                    p  print it, then hang (output before the deadline is dropped)  b  write 256 KiB (fills the buffer) */
#include "duop_config.h"
#include "duop_abi.h"
#include "duop_pal.h"
#include "duop_string.h"

static char g_path[PATH_MAX + 32], g_buf[1 << 18];

static void put(int fd, const char *s) { (void)os_write(fd, s, str_len(s)); }

static const char *in_dir(const char *dir, const char *name)
{
    size_t n = str_copy(g_path, dir, PATH_MAX);
    (void)str_copy(g_path + n, name, 32);
    return g_path;
}

static intptr_t slurp(const char *dir, const char *name)
{
    intptr_t fd = os_openat(AT_FDCWD, in_dir(dir, name), O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) return 0;
    intptr_t n = os_read((int)fd, g_buf, sizeof g_buf);
    (void)os_close((int)fd);
    return n < 0 ? 0 : n;
}

static void log_fd(int log, int fd)
{
    char link[64] = "/proc/self/fd/0", target[128];
    link[14] = (char)('0' + fd);
    intptr_t n = os_readlinkat(AT_FDCWD, link, target, sizeof target - 1);
    target[n < 0 ? 0 : n] = 0;
    put(log, " fd"); put(log, link + 14); put(log, "="); put(log, target);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 6) return 2;
    const char *dir = argv[5];
    intptr_t log = os_openat(AT_FDCWD, in_dir(dir, "/.fake_log"), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (log >= 0) {
        for (int i = 0; i < argc; i++) { put((int)log, i == 5 ? "<dir>" : argv[i]); put((int)log, " "); }
        put((int)log, "|");
        for (char **e = envp; *e; e++) { put((int)log, " "); put((int)log, *e); }
        log_fd((int)log, 0);
        log_fd((int)log, 2);
        put((int)log, "\n");
        (void)os_close((int)log);
    }
    char mode = slurp(dir, "/.fake_mode") > 0 ? g_buf[0] : 'o';
    if (mode == 'h') for (;;) (void)os_poll_in(-1, 1000);
    if (mode == 'b') {
        for (size_t i = 0; i < sizeof g_buf; i++) g_buf[i] = 'x';
        intptr_t w = os_write(1, g_buf, sizeof g_buf);
        return w < 0 ? 3 : 0;
    }
    intptr_t n = slurp(dir, "/.fake_out");
    (void)os_write(1, g_buf, (size_t)n);
    if (mode == 'p') for (;;) (void)os_poll_in(-1, 1000);
    return mode == 'f' ? 1 : 0;
}
