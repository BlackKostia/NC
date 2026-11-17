/* Freestanding harness: four fixed expansions printed as "<rc>|<out>". */
#include "duop_config_expand.h"
#include "duop_string.h"

static void show(const char *tmpl, size_t cap, const ConfigExpandCtx *c)
{
    char out[128], line[160];
    intptr_t rc = config_expand_cmd(tmpl, out, cap, c);
    size_t n = 0;
    if (rc < 0) line[n++] = '-';
    n += u64_to_dec((uint64_t)(rc < 0 ? -rc : rc), line + n);
    line[n++] = '|';
    for (size_t i = 0; out[i]; i++) line[n++] = out[i];
    line[n++] = '\n';
    (void)os_write(1, line, n);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)envp; (void)auxv;
    static const char names[] = "p q\0r\0";
    ConfigExpandCtx c = {"a'b", "/x/y", names, "/d", "/e"};
    show("echo %f \"x\\\"y\" 100%%", 128, &c);
    show("echo %f %p %d %D %F", 20, &c);
    show("ls %s", 128, &c);
    ConfigExpandCtx c2 = {"q", nullptr, nullptr, nullptr, nullptr};
    show("sh -c 'echo %f'", 128, &c2);
    return 0;
}
