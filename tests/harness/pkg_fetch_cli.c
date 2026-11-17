/* Freestanding harness: the frozen asm pkg_fetch_url (x86_64, ref_ prefix) and src/fs/pkg_fetch.c (compiled into this unit, path
 * in PF_SRC) with a scripted clock and poll: both call pf_clock / pf_poll instead of os_clock_ms / os_poll_in.
 *   argv: <ref|c> <step_ms> <url> <dest>
 *   step 0  the real clock and a real poll (a download that really runs)
 *   step k  every clock call returns k * (number of calls) and poll returns at once: the 60 s timeout arrives after a fixed number
 *           of clock calls, whatever the helper does
 * Prints "ret=<r> clock=<calls> poll=<fd>/<ms>" (poll: the arguments of the last poll, or "-"). */
#include "script_cli.h"
#include "duop_pkg.h"

static int64_t g_step, g_clock_calls, g_poll_n;
static int g_poll_fd, g_poll_ms;

int64_t pf_clock(void);
int pf_poll(int fd, int timeout_ms);

int64_t pf_clock(void)
{
    g_clock_calls++;
    return g_step ? g_step * g_clock_calls : os_clock_ms();
}

int pf_poll(int fd, int timeout_ms)
{
    g_poll_n++;
    g_poll_fd = fd;
    g_poll_ms = timeout_ms;
    return g_step ? 0 : os_poll_in(fd, timeout_ms);
}

#define os_clock_ms pf_clock
#define os_poll_in pf_poll
#include PF_SRC
#undef os_clock_ms
#undef os_poll_in

#ifdef __x86_64__
extern int ref_pkg_fetch_url(char **envp, const char *url, const char *dest_path);
#endif

static int64_t dec(const char *s) { int64_t v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0'); return v; }

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 5) return 2;
    g_step = dec(argv[2]);
    int r;
#ifdef __x86_64__
    if (argv[1][0] == 'r') r = ref_pkg_fetch_url(envp, argv[3], argv[4]);
    else
#endif
    r = pkg_fetch_url(envp, argv[3], argv[4]);
    sc_put("ret="); sc_num(r);
    sc_put(" clock="); sc_num(g_clock_calls);
    sc_put(" poll=");
    if (g_poll_n) { sc_num(g_poll_fd); sc_put("/"); sc_num(g_poll_ms); } else sc_put("-");
    sc_put("\n");
    sc_flush();
    return 0;
}
