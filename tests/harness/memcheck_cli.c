/* Freestanding harness: frozen asm memcheck (ref_ prefix) next to src/core/memcheck.c (both built with MEMCHECK=1).
 * <ref|c> reads a script on stdin, one command per line, numbers in hex:
 *   I                      mc_init(envp)  ($DUOP_MEMCHECK_LOG selects the log file)
 *   A <ptr> <size> <caller>   mc_on_alloc          F <ptr> <caller>   mc_on_free
 *   R <old> <new> <size> <caller>   mc_on_realloc  P   mc_report
 * The log lines go to the log file / stderr, so the test diffs those byte for byte. */
#include "script_cli.h"

extern void ref_mc_init(char **);
extern void ref_mc_on_alloc(void *, size_t, void *);
extern void ref_mc_on_free(void *, void *);
extern void ref_mc_on_realloc(void *, void *, size_t, void *);
extern void ref_mc_report(void);
void mc_init(char **);
void mc_report(void);

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 2) return 2;
    bool ref = !str_cmp(argv[1], "ref");
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        uint64_t a = 0, b = 0, c = 0, d = 0;
        const char *p = line + 1;
        switch (line[0]) {
        case 'I': if (ref) ref_mc_init(envp); else mc_init(envp); break;
        case 'A': sc_hex(sc_hex(sc_hex(p, &a), &b), &c);
                  if (ref) ref_mc_on_alloc((void *)a, b, (void *)c); else mc_on_alloc((void *)a, b, (void *)c); break;
        case 'F': sc_hex(sc_hex(p, &a), &b);
                  if (ref) ref_mc_on_free((void *)a, (void *)b); else mc_on_free((void *)a, (void *)b); break;
        case 'R': sc_hex(sc_hex(sc_hex(sc_hex(p, &a), &b), &c), &d);
                  if (ref) ref_mc_on_realloc((void *)a, (void *)b, c, (void *)d); else mc_on_realloc((void *)a, (void *)b, c, (void *)d); break;
        case 'P': if (ref) ref_mc_report(); else mc_report(); break;
        default: break;
        }
    }
    sc_flush();
    return 0;
}
