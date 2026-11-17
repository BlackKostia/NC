/* Freestanding harness for src/core/syscall.c: prints "name=value" lines; the big write goes to stdout last. */
#include "duop_string.h"
#include "duop_sys.h"

static void say(const char *name, int64_t v)
{
    char out[80];
    size_t m = 0;
    while (*name) out[m++] = *name++;
    out[m++] = '=';
    if (v < 0) out[m++] = '-';
    m += u64_to_dec(v < 0 ? (uint64_t)-v : (uint64_t)v, out + m);
    out[m++] = '\n';
    (void)os_write(1, out, m);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)auxv;
    static char *env1[] = {(char *)"HOME=/h", (char *)"HOMEX=1", (char *)"EMPTY=", (char *)"PATH=/bin:/usr/bin", nullptr};
    const char *v;
    say("env_home", (v = env_getenv(env1, "HOME")) && v[0] == '/' && v[1] == 'h' && !v[2]);
    say("env_prefix_miss", env_getenv(env1, "HOM") == nullptr);
    say("env_empty", (v = env_getenv(env1, "EMPTY")) && !v[0]);
    say("env_null", env_getenv(nullptr, "HOME") == nullptr);

    char *sh_exit[] = {(char *)"sh", (char *)"-c", (char *)"exit 5", nullptr};
    say("argv_status", sys_exec_argv("/bin/sh", sh_exit, envp));
    say("argv_missing", sys_exec_argv("/nonexistent/duop-exe", sh_exit, envp));
    say("sh_arg_status", sys_exec_sh_arg("exit 3", nullptr, envp));
    say("sh_arg_args", sys_exec_sh_arg("test \"$1\" = hello", "hello", envp));
    char *bg[] = {(char *)"sh", (char *)"-c", (char *)"echo LEAK; echo LEAK >&2; exit 4", nullptr};
    say("bg_status", sys_exec_argv_bg("/bin/sh", bg, envp));
    say("open_external_nodisplay", sys_open_external("/tmp/x", env1));
    static char *env2[] = {(char *)"DISPLAY=:0", (char *)"PATH=/nonexistent", nullptr};
    say("open_external_display", sys_open_external("/tmp/x", env2));

    signals_install();
    (void)os_kill((int)os_getpid(), 28);
    (void)os_kill((int)os_getpid(), 15);
    say("sigwinch", g_sigwinch);
    say("sigterm", g_sigterm);
    say("fault_slot_installed", 1);

    static uint8_t big[300000];
    for (size_t i = 0; i < sizeof big; i++) big[i] = (uint8_t)('a' + i % 26);
    say("big_write", sys_write_all(1, big, sizeof big));
    return 0;
}
