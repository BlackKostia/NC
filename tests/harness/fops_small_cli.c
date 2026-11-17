/* Freestanding harness: frozen asm fs_read_file_alloc / copy_link_at (ref_ prefix) next to src/fs/file_ops_read.c.
 *   read <path> <max>          both readers: "ret len" + the buffers compared byte for byte
 *   link <srcdir> <name> <dstdir> <name2> [dst2]   copy_link_at by both (the second run goes to <name2> for the C version) */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

extern intptr_t ref_fs_read_file_alloc(const char *, size_t, void **, size_t *);
extern intptr_t ref_copy_link_at(int, const char *, int, const char *);

static int g_progress;
void fs_progress_item(void) { g_progress++; }               /* the progress counter of the copy engine, still assembly */

static char g_out[1 << 14];
static size_t g_n;
static void flush(void) { (void)os_write(1, g_out, g_n); g_n = 0; }
static void put(const char *s) { while (*s) { if (g_n >= sizeof g_out - 8) flush(); g_out[g_n++] = *s++; } }
static void num(int64_t v)
{
    char t[24];
    if (v < 0) { put("-"); v = -v; }
    t[u64_to_dec((uint64_t)v, t)] = 0;
    put(t);
}

static uint64_t dec(const char *s)
{
    uint64_t v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (uint64_t)(*s++ - '0');
    return v;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc >= 4 && !str_cmp(argv[1], "read")) {
        void *a = (void *)0x1, *b = (void *)0x1;
        size_t la = 77, lb = 77;
        intptr_t ra = ref_fs_read_file_alloc(argv[2], dec(argv[3]), &a, &la), rb = fs_read_file_alloc(argv[2], dec(argv[3]), &b, &lb);
        bool same = ra == rb && la == lb && (a == nullptr) == (b == nullptr);
        for (size_t i = 0; same && a && i <= la; i++) same = ((char *)a)[i] == ((char *)b)[i];       /* includes the NUL terminator */
        num(ra); put(" "); num(rb); put(" "); num((int64_t)lb); put(same ? " same" : " DIFFERENT"); put("\n");
    } else if (argc >= 6 && !str_cmp(argv[1], "link")) {
        int sd = (int)os_openat(AT_FDCWD, argv[2], O_RDONLY | O_DIRECTORY, 0), dd = (int)os_openat(AT_FDCWD, argv[4], O_RDONLY | O_DIRECTORY, 0);
        const char *refname = argv[5], *cname = argc > 6 ? argv[6] : argv[5];
        g_progress = 0;
        intptr_t ra = ref_copy_link_at(sd, argv[3], dd, refname);
        int pa = g_progress;
        g_progress = 0;
        intptr_t rb = copy_link_at(sd, argv[3], dd, cname);
        num(ra); put(" "); num(rb); put(" "); num(pa); put(" "); num(g_progress); put("\n");
    }
    flush();
    return 0;
}
