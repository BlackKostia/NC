/* include/duop_cli.h - command line of the duop binary (src/app/cli_args.c, license.c). Freestanding C23.
 *
 * Same grammar as the assembly entry point (src/main.s): -h/--help, -v/-V/--version, -L/--license, --lang ID | -l ID | --lang=ID,
 * --choosedir FILE | --choosedir=FILE, up to two positional directories, and `pkg ...` as the first argument. */
#pragma once
#include "duop_abi.h"

typedef struct CliArgs {
    int lang;                      /* language index from --lang (i18n_find, English when unknown), -1 = detect from the environment */
    bool help, version, license;   /* print-and-exit requests; help wins over version over license */
    bool pkg;                      /* argv[1] == "pkg": the package manager sub-command owns the rest of argv */
    const char *choosedir;         /* file that receives the directory the user leaves in, or nullptr */
    const char *left, *right;      /* start directories (first two positionals), or nullptr */
} CliArgs;

extern const char duop_license_text[];   /* the MIT license, byte-identical to the LICENSE file */

/* Parse argv (i18n_load must have run: --lang looks the id up). Never fails; unknown options are positionals. */
void cli_parse(int argc, char **argv, CliArgs *out);

/* Print the text a help / version / license request asks for (language: --lang, else LC_ALL/LC_MESSAGES/LANG) to stdout.
 * Returns true when the request was one of those, false when the program should run normally. */
bool cli_print_info(const CliArgs *args, char **envp);
