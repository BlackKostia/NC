/* Freestanding harness for src/app/cli_args.c: the parsed command line and the info output, one script line per invocation.
 *   P <arg>...   cli_parse(["duop", arg...]) and print every field
 *   I <arg>...   cli_parse + cli_print_info: prints the real output text, then "info=<0|1>"
 * The environment (DUOP_LANGS, LC_ALL, LANG ...) comes from the process, so the test controls the language packs. */
#include "script_cli.h"
#include "duop_cli.h"
#include "duop_tui.h"

static void field(const char *name, const char *v)
{
    sc_put(name);
    sc_put("=");
    sc_put(v ? v : "(null)");
    sc_put(" ");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)auxv;
    i18n_load(envp);
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *av[32] = { "duop" };
        int n = 1;
        for (char *p = line + 1; *p && n < 31;) {
            while (*p == ' ') *p++ = 0;
            if (!*p) break;
            av[n++] = p;
            while (*p && *p != ' ') p++;
        }
        av[n] = nullptr;
        CliArgs a;
        cli_parse(n, av, &a);
        if (line[0] == 'P') {
            sc_put("lang="); sc_num(a.lang);
            sc_put(a.help ? " help" : " -"); sc_put(a.version ? " version" : " -"); sc_put(a.license ? " license" : " -"); sc_put(a.pkg ? " pkg " : " - ");
            field("choosedir", a.choosedir); field("left", a.left); field("right", a.right);
            sc_put("\n");
        } else {
            sc_flush();
            bool printed = cli_print_info(&a, envp);
            sc_put("info="); sc_num(printed); sc_put("\n");
        }
    }
    sc_flush();
    return 0;
}
