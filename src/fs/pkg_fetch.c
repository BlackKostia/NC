/* src/fs/pkg_fetch.c - fork + exec curl/wget for the Duop package manager (freestanding C23; replaces pkg_fetch.s, kept as
 * tests/harness/pkg_fetch_reference.s).
 *
 * The child tries /usr/bin/curl, /bin/curl, /usr/bin/wget, /bin/wget in that order and exits 127 when none can be executed. The
 * parent never blocks the UI for longer than PKG_FETCH_TIMEOUT_MS: it polls the child with WNOHANG every PKG_FETCH_POLL_MS and
 * kills (SIGKILL) and reaps it once the deadline has passed. The URL always follows "--", so it can never be taken for an option. */
#include "duop_pkg.h"
#include "duop_pal.h"

static const char pf_curl1[] = "/usr/bin/curl";
static const char pf_curl2[] = "/bin/curl";
static const char pf_wget1[] = "/usr/bin/wget";
static const char pf_wget2[] = "/bin/wget";

/* the child: never returns */
[[noreturn]] static void pf_child(char **envp, const char *url, const char *dest)
{
    os_sig_reset_pipe();
    os_mark_child_forked();
    const char *argv[] = {pf_curl1, "-fsSL", "-o", dest, "--", url, nullptr};      /* curl -fsSL -o dest -- url */
    (void)os_execve(pf_curl1, (char *const *)argv, envp);
    (void)os_execve(pf_curl2, (char *const *)argv, envp);
    argv[0] = pf_wget1;                                                           /* wget -q -O dest -- url */
    argv[1] = "-q";
    argv[2] = "-O";
    (void)os_execve(pf_wget1, (char *const *)argv, envp);
    (void)os_execve(pf_wget2, (char *const *)argv, envp);
    os_exit(127);
}

/* SIGKILL the timed-out child and reap it (bounded: SIGKILL cannot be caught) */
static void pf_kill_reap(int pid)
{
    int status;
    (void)os_kill(pid, SIGKILL);                      /* fault-checked: timed-out fetch termination */
    while (os_wait4(pid, &status, 0, nullptr) == -EINTR) {}
}

int pkg_fetch_url(char **envp, const char *url, const char *dest_path)
{
    intptr_t pid = os_fork();
    if (pid < 0) return -1;
    if (pid == 0) pf_child(envp, url, dest_path);
    int64_t deadline = os_clock_ms() + PKG_FETCH_TIMEOUT_MS;
    for (;;) {
        int status;
        intptr_t r = os_wait4((int)pid, &status, WNOHANG, nullptr);
        if (r == -EINTR) continue;
        if (r < 0) return -1;
        if (r > 0) return status == 0 ? 0 : -1;
        if (os_clock_ms() >= deadline) {
            pf_kill_reap((int)pid);
            return -1;
        }
        (void)os_poll_in(-1, PKG_FETCH_POLL_MS);      /* wake-up interval */
    }
}
