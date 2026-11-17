/* src/app/cli_args.c - command line parsing and the --help / --version / --license output (freestanding C23).
 *
 * The grammar and the order in which options are tried are those of the assembly entry point (src/main.s), so both entry
 * points print byte-identical text; tests/test_headless.py compares them. */
#include "duop_cli.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "i18n_slots.h"

/* option value that selects an interface language: id, code or locale; English when no pack matches */
static int cli_lang_value(const char *value)
{
    int idx = i18n_find(value);
    return idx < 0 ? 0 : idx;
}

static bool cli_is(const char *arg, const char *a, const char *b, const char *c)
{
    return !str_cmp(arg, a) || (b && !str_cmp(arg, b)) || (c && !str_cmp(arg, c));
}

/* handles one argument; returns how many extra arguments it consumed (an option value) */
static int cli_option(const char *arg, const char *next, CliArgs *out)
{
    if (cli_is(arg, "-h", "--help", nullptr)) out->help = true;
    else if (cli_is(arg, "-v", "-V", "--version")) out->version = true;
    else if (cli_is(arg, "-L", "--license", nullptr)) out->license = true;
    else if (cli_is(arg, "--lang", "-l", nullptr)) {
        if (!next) return 0;
        out->lang = cli_lang_value(next);
        return 1;
    } else if (str_starts_with(arg, "--lang=")) out->lang = cli_lang_value(arg + 7);
    else if (!str_cmp(arg, "--choosedir")) {
        if (!next) return 0;
        out->choosedir = next;
        return 1;
    } else if (str_starts_with(arg, "--choosedir=")) out->choosedir = arg + 12;
    else if (!out->left) out->left = arg;
    else if (!out->right) out->right = arg;
    return 0;
}

void cli_parse(int argc, char **argv, CliArgs *out)
{
    *out = (CliArgs){ .lang = -1 };
    out->pkg = argc >= 2 && !str_cmp(argv[1], "pkg");
    for (int i = 1; i < argc; i++) i += cli_option(argv[i], i + 1 < argc ? argv[i + 1] : nullptr, out);
}

bool cli_print_info(const CliArgs *args, char **envp)
{
    if (!args->help && !args->version && !args->license) return false;
    const char *text = duop_license_text;
    if (args->help || args->version) {
        const LangStrings *lang = i18n_set_lang(args->lang >= 0 ? args->lang : i18n_detect_env(envp));
        text = args->help ? lang->s[LS_cli_usage] : lang->s[LS_cli_version];
    }
    (void)sys_write_all(STDOUT_FD, text, str_len(text));
    return true;
}
