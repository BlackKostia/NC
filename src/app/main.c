/* src/app/main.c - Duop process entry point (called from src/os/<os>/<arch>/pal_start.s, freestanding C23). */
#include "duop_abi.h"
#include "duop_app_int.h"
#include "duop_cli.h"
#include "duop_oop.h"
#include "duop_pkg.h"
#include "duop_sys.h"
#include "duop_tui.h"

static int main_run_tui(const char *left, const char *right, char **envp,
                        int lang_override, const char *choosedir)
{
    if (input_probe_eof()) return 0;
    signals_install();
    (void)term_enter_raw();
    App *app = App_new(left, right, envp, lang_override);
    if (!app) {
        term_exit_raw();
        return 1;
    }
    App_run(app);
    App_write_choosedir(app, choosedir);
    Object_free((Object *)app);
    term_exit_raw();
    return 0;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    g_envp = envp;
#ifdef MEMCHECK
    mc_init(envp);
#endif
    i18n_load(envp);
    CliArgs args;
    cli_parse(argc, argv, &args);
    int rc = 0;
    if (args.pkg) rc = pkg_cli_dispatch(argc, argv, envp);
    else if (!cli_print_info(&args, envp))
        rc = main_run_tui(args.left, args.right, envp, args.lang, args.choosedir);
#ifdef MEMCHECK
    mc_report();
#endif
    return rc;
}
