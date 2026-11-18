/* Freestanding harness: the frozen asm VFS-provider runner (pkg_vfs_reference.s, x86_64, ref_ prefix) or src/fs/pkg_vfs.c
 * (compiled into this unit, path in PKV_SRC), with the real package manager. argv[1] = ref | c; the root and the helper's
 * environment come from the process environment. Script on stdin: one URI per line; for each, the provider's output, then
 * "= r=<result> ms=<duration rounded down to 500 ms>". */
#include "script_cli.h"
#include "duop_pkg.h"

#include PKV_SRC

#ifdef __x86_64__
extern int ref_pkg_vfs_list_stdout(char **, const char *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        sc_put("> "); sc_esc(line); sc_put("\n");
        sc_flush();
        int64_t t0 = os_clock_ms();
        int r = CALL(pkg_vfs_list_stdout, envp, line);
        int64_t ms = os_clock_ms() - t0;
        sc_put("= r="); sc_num(r); sc_put(" ms="); sc_num(ms / 500 * 500); sc_put("\n");
        sc_flush();
    }
    return 0;
}
