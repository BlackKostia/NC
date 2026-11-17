/* aarch64 smoke harness: the C data_dirs scan alone (no frozen asm exists for that target). */
#include "duop_string.h"
#include "duop_tui.h"

static void load(const char *path, const char *name)
{
    char line[9000];
    size_t n = 0;
    line[n++] = 'C';
    line[n++] = ' ';
    for (const char *s = path; *s; s++) line[n++] = *s;
    line[n++] = ' ';
    for (const char *s = name; *s; s++) line[n++] = *s;
    line[n++] = '\n';
    (void)os_write(1, line, n);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)auxv;
    const DataSpec spec = {"DUOP_TESTDATA=", "layouts", ".layout", load};
    data_dirs_scan(envp, &spec);
    return 0;
}
