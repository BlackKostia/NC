/* src/app/main_headless.c - entry point of the `headless` build (make headless, any ARCH): the command line without the TUI.
 *
 * Prints --help / --version / --license exactly like the full binary and stops there; everything that would open the terminal
 * UI (or the pkg sub-command) reports that this build has none and exits 2. It links the portable C core, tui (i18n packs)
 * and the PAL, so it proves the C23 layers on every target before the UI and the application controller are ported. */
#include "duop_cli.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"

static void headless_say(const char *msg) { (void)sys_write_all(STDERR_FD, msg, str_len(msg)); }

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    g_envp = envp;
    i18n_load(envp);
    CliArgs args;
    cli_parse(argc, argv, &args);
    if (args.pkg) {
        headless_say("duop (headless build): the pkg sub-command is not available\n");
        return 2;
    }
    if (cli_print_info(&args, envp)) return 0;
    headless_say("duop (headless build): no terminal UI; try --help, --version or --license\n");
    return 2;
}
