/* A stand-in curl/wget for tests/test_c_pkg_fetch.py (bind-mounted over /usr/bin in a user + mount namespace). It appends
 * "<argv joined by blanks> tag=<$PF_TAG>" to $PF_LOG, then acts on $PF_MODE:
 *   ok    writes "fake:<argv[0]>" to argv[3] (the -o / -O destination) and exits 0
 *   fail  exits 22 (curl -f on an HTTP error)        sig   kills itself with SIGTERM        hang  sleeps until killed */
#include "duop_abi.h"
#include "duop_pal.h"
#include "duop_string.h"

static const char *env(char **envp, const char *key)
{
    size_t n = str_len(key);
    for (; *envp; envp++)
        if (str_starts_with(*envp, key) && (*envp)[n] == '=') return *envp + n + 1;
    return "";
}

static void put(int fd, const char *s) { (void)os_write(fd, s, str_len(s)); }

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    intptr_t fd = os_openat(AT_FDCWD, env(envp, "PF_LOG"), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd >= 0) {
        for (int i = 0; i < argc; i++) { put((int)fd, argv[i]); put((int)fd, " "); }
        put((int)fd, "tag="); put((int)fd, env(envp, "PF_TAG")); put((int)fd, "\n");
        (void)os_close((int)fd);
    }
    const char *mode = env(envp, "PF_MODE");
    if (!str_cmp(mode, "ok") && argc > 3) {
        intptr_t out = os_openat(AT_FDCWD, argv[3], O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (out < 0) return 23;
        put((int)out, "fake:"); put((int)out, argv[0]);
        (void)os_close((int)out);
        return 0;
    }
    if (!str_cmp(mode, "sig")) (void)os_kill((int)os_getpid(), SIGTERM);
    if (!str_cmp(mode, "hang")) for (;;) (void)os_poll_in(-1, 1000);
    return 22;
}
