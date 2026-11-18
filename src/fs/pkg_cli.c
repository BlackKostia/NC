/* src/fs/pkg_cli.c - `duop pkg <list|update|search|upgrade|install|remove|verify|vfs-list>` (freestanding C23; replaces pkg_cli.s,
 * kept as tests/harness/pkg_cli_reference.s). The exit code is 0 or 1; results go to stdout ("OK" / "Error" for actions). */
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_sys.h"

#define PKC_MAX_LIST 64

static void pkc_puts(const char *s)
{
    (void)sys_write_all(1, s, str_len(s));
}

static void pkc_row(const char *a, const char *b, const char *c, const char *d)
{
    const char *cols[] = {a, "  ", b, "  ", c, "  ", d, "\n"};
    for (size_t i = 0; i < sizeof cols / sizeof cols[0]; i++) pkc_puts(cols[i]);
}

static int pkc_do_list(char **envp)
{
    PkgEntry *e = mem_alloc(PKC_MAX_LIST * sizeof *e);
    if (!e) return 1;
    int n = pkg_list(envp, e, PKC_MAX_LIST);
    for (int i = 0; i < n; i++) pkc_row(e[i].name, e[i].version, e[i].kind, e[i].desc);
    mem_free(e);
    return 0;
}

static int pkc_do_search(char **envp, const char *query)
{
    PkgRegEntry *e = mem_alloc(PKC_MAX_LIST * sizeof *e);
    if (!e) return 1;
    int n = pkg_registry_list(envp, e, PKC_MAX_LIST);
    for (int i = 0; i < n; i++)
        if (!query || str_contains_ci(e[i].name, query)) pkc_row(e[i].name, e[i].version, e[i].kind, e[i].desc);
    mem_free(e);
    return 0;
}

/* a path or URL; failing that (and without a pinned hash) a registry name installed from its URL with its hash */
static int pkc_do_install(char **envp, const char *what, const char *sha)
{
    if (pkg_install_archive(envp, what, sha) == 0) return 0;
    PkgRegEntry reg;
    if (sha || pkg_registry_find(envp, what, &reg) != 0) return -1;
    return pkg_install_archive(envp, reg.url, reg.sha256);
}

/* argv[4] / argv[5]: the pinned hash after "--sha256" (anything else: none) */
static const char *pkc_sha_arg(int argc, char **argv)
{
    return argc >= 6 && !str_cmp(argv[4], "--sha256") ? argv[5] : nullptr;
}

int pkg_cli_dispatch(int argc, char **argv, char **envp)
{
    const char *cmd = argc >= 3 ? argv[2] : "";
    int r;
    if (!str_cmp(cmd, "list")) return pkc_do_list(envp);
    if (!str_cmp(cmd, "update")) r = pkg_registry_update(envp);
    else if (!str_cmp(cmd, "upgrade")) r = pkg_registry_upgrade(envp);
    else if (!str_cmp(cmd, "search")) return pkc_do_search(envp, argc >= 4 ? argv[3] : nullptr);
    else if (argc < 4) goto usage;
    else if (!str_cmp(cmd, "install")) r = pkc_do_install(envp, argv[3], pkc_sha_arg(argc, argv));
    else if (!str_cmp(cmd, "remove")) r = pkg_remove(envp, argv[3]);
    else if (!str_cmp(cmd, "verify")) r = pkg_verify(envp, argv[3]);
    else if (!str_cmp(cmd, "vfs-list")) {
        if (pkg_vfs_list_stdout(envp, argv[3]) == 0) return 0;
        r = -1;
    } else goto usage;
    pkc_puts(r ? "Error\n" : "OK\n");
    return r ? 1 : 0;
usage:
    pkc_puts("Usage: duop pkg <list|update|search [q]|upgrade|install <path|url|name> [--sha256 <hex>]|remove <name>|verify <name>|"
             "vfs-list <uri>>\n");
    return 1;
}
