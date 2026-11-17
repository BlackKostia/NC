/* Freestanding harness: for each argv[i] (decimal epoch) prints "<format_datetime>|<size>|<perms>" using the C modules. */
#include "duop_string.h"

static int64_t parse(const char *s)
{
    bool neg = *s == '-';
    if (neg) s++;
    int64_t v = 0;
    while (*s) v = v * 10 + (*s++ - '0');
    return neg ? -v : v;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    for (int i = 1; i < argc; i++) {
        int64_t t = parse(argv[i]);
        char line[96], tmp[32];
        size_t n = 0;
        format_datetime(t, tmp);
        for (size_t k = 0; tmp[k]; k++) line[n++] = tmp[k];
        line[n++] = '|';
        format_size(t, tmp);
        for (size_t k = 0; tmp[k]; k++) line[n++] = tmp[k];
        line[n++] = '|';
        format_perms((uint32_t)t, tmp);
        for (size_t k = 0; tmp[k]; k++) line[n++] = tmp[k];
        line[n++] = '\n';
        (void)os_write(1, line, n);
    }
    return 0;
}
