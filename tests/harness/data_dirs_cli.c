/* Freestanding harness: frozen asm data_dirs (ref_ prefix) next to src/tui/data_dirs.c on the real kernel stack.
 *   scan            -> "R|C <path> <name>" for each file either implementation hands to its loader
 *   read <p> <cap>  -> "R|C <rc> <content>" from data_read_file
 * The auxiliary vector (AT_EXECFN) is the real one, so the test copies the binary around to exercise the binary-dir lookup. */
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"

extern void ref_data_dirs_scan(char **envp, const DataSpec *spec);
extern intptr_t ref_data_read_file(const char *path, char *buf, size_t cap);

static void out(const char *tag, const char *a, const char *b)
{
    char line[9000];
    size_t n = 0;
    for (const char *s = tag; *s; s++) line[n++] = *s;
    line[n++] = ' ';
    for (const char *s = a; *s && n < 9000 - 100; s++) line[n++] = *s;
    line[n++] = ' ';
    for (const char *s = b; *s && n < 9000 - 2; s++) line[n++] = *s;
    line[n++] = '\n';
    (void)os_write(1, line, n);
}
static void dec(intptr_t v, char *o)
{
    if (v < 0) { *o++ = '-'; v = -v; }
    o[u64_to_dec((uint64_t)v, o)] = 0;
}
static void ref_load(const char *path, const char *name) { out("R", path, name); }
static void c_load(const char *path, const char *name) { out("C", path, name); }

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc >= 2 && !str_cmp(argv[1], "scan")) {
        const DataSpec ref = {"DUOP_TESTDATA=", "layouts", ".layout", ref_load};
        const DataSpec cs = {"DUOP_TESTDATA=", "layouts", ".layout", c_load};
        ref_data_dirs_scan(envp, &ref);
        data_dirs_scan(envp, &cs);
        return 0;
    }
    if (argc >= 4 && !str_cmp(argv[1], "read")) {
        size_t cap = 0;
        for (const char *s = argv[3]; *s; s++) cap = cap * 10 + (size_t)(*s - '0');
        static char a[70000], b[70000];
        for (size_t i = 0; i < sizeof a; i++) a[i] = b[i] = 'Z';          /* canaries: nothing past cap may change */
        intptr_t ra = cap ? ref_data_read_file(argv[2], a, cap) : -77,     /* the asm reads without bound at cap == 0 */
                 rb = data_read_file(argv[2], b, cap);
        char t[24], u[24];
        dec(ra, t);
        dec(rb, u);
        out("R", t, ra >= 0 ? a : "");
        out("C", u, rb >= 0 ? b : "");
        size_t lim = cap;
        bool same = true;
        for (size_t i = lim; i < sizeof a; i++) same &= a[i] == 'Z' && b[i] == 'Z';
        out("TAIL", same ? "intact" : "CLOBBERED", "");
        return 0;
    }
    return 2;
}
