/* Freestanding harness: frozen asm git_repo_trusted (ref_ prefix) against src/fs/git_trust.c; one path per stdin line -> "ref c". */
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_sys.h"

extern int ref_git_repo_trusted(const char *);

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)envp; (void)auxv;
    static char in[1 << 20], out[1 << 16];
    size_t n = 0, o = 0;
    intptr_t r;
    while (n < sizeof in - 1 && (r = os_read(0, in + n, sizeof in - 1 - n)) > 0) n += (size_t)r;
    in[n] = 0;
    for (char *line = in; *line;) {
        char *eol = line;
        while (*eol && *eol != '\n') eol++;
        char *next = *eol ? eol + 1 : eol;
        *eol = 0;
        int a = ref_git_repo_trusted(line), b = git_repo_trusted(line);
        if (o + 8 >= sizeof out) { (void)os_write(1, out, o); o = 0; }
        out[o++] = (char)('0' + a); out[o++] = ' '; out[o++] = (char)('0' + b); out[o++] = '\n';
        line = next;
    }
    (void)os_write(1, out, o);
    return 0;
}
