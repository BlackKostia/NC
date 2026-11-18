/* Freestanding harness: the frozen asm package-archive helpers (pkg_archive_reference.s, x86_64, ref_ prefix) or src/fs/pkg_archive.c
 * (compiled into this unit, path in PKA_SRC), over the real archive parsers. Paths are relative to the working directory, so the
 * Python test runs each implementation in its own identical tree. argv[1] = ref | c. Script on stdin:
 *   M <path>            pkg_mkdir_p                 W <path> <len>   pkg_write_file of <len> pattern bytes
 *   X <path>            pkg_ensure_exec, then the mode
 *   F <file> [len]      pkg_parse_manifest of the file (or its first <len> bytes; negative allowed) between two canaries
 *   A <archive> <s|-> <oom>  pkg_load_archive(_sha) with the <oom>-th allocation failing (0: none), under the fault guard; then
 *                       every entry extracted to x<i> (result, length, hash) and freed */
#include "script_cli.h"
#include "duop_pkg.h"
#include "duop_arc.h"
#include "duop_pal.h"

static int g_alloc_n, g_alloc_fail;
void *fake_mem_alloc(size_t n);
void *fake_mem_alloc(size_t n) { return ++g_alloc_n == g_alloc_fail ? nullptr : mem_alloc(n); }

#define mem_alloc fake_mem_alloc
#include PKA_SRC
#undef mem_alloc

#ifdef __x86_64__
extern void ref_pkg_mkdir_p(const char *);
extern int ref_pkg_write_file(const char *, const void *, uint64_t), ref_pkg_ensure_exec(const char *);
extern void ref_pkg_parse_manifest(const char *, int, PkgEntry *);
extern ArcCtx *ref_pkg_load_archive(const char *), *ref_pkg_load_archive_sha(const char *, char *);
extern void ref_pkg_free_archive(ArcCtx *);
extern int ref_pkg_extract_entry_to(ArcCtx *, ArcEntry *, const char *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static uint8_t g_buf[1 << 23];
static struct { uint8_t pre[512]; PkgEntry e; uint8_t post[512]; } g_man;

static int sc_split(char *line, char **f, int max)
{
    int n = 0;
    while (*line && n < max) {
        while (*line == ' ') *line++ = 0;
        if (!*line) break;
        f[n++] = line;
        while (*line && *line != ' ') line++;
    }
    return n;
}

static int64_t num(const char *s)
{
    int64_t sign = *s == '-' ? (s++, -1) : 1, v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return sign * v;
}

static uint64_t fnv(const uint8_t *p, size_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull;
    return h;
}

static void cmd_manifest(char **f, int n)
{
    size_t got = 0;
    if (fs_read_file_head(f[1], g_buf, sizeof g_buf, &got) < 0) { sc_put("F noread"); return; }
    for (size_t i = 0; i < sizeof g_man; i++) ((uint8_t *)&g_man)[i] = 0xA5;
    CALLV(pkg_parse_manifest, (const char *)g_buf, n > 2 ? (int)num(f[2]) : (int)got, &g_man.e);
    sc_put("F ["); sc_esc(g_man.e.name); sc_put("|"); sc_esc(g_man.e.version); sc_put("|"); sc_esc(g_man.e.kind); sc_put("|");
    sc_esc(g_man.e.desc); sc_put("]");
    int bad = 0;
    for (size_t i = 0; i < 512; i++) bad += (g_man.pre[i] != 0xA5) + (g_man.post[i] != 0xA5);
    for (size_t i = 0; i < sizeof g_man.e.rest; i++) bad += g_man.e.rest[i] != 0;
    sc_put(" canary="); sc_num(bad);
}

static void cmd_archive(char **f)
{
    char sha[80];
    mem_zero(sha, sizeof sha);
    bool with_sha = f[2][0] == 's';
    g_alloc_n = 0;
    g_alloc_fail = (int)num(f[3]);
    ArcCtx *volatile ctx = nullptr;
    TryFrame tf;
    if (os_try_begin(&tf) == 0) {
        ctx = with_sha ? CALL(pkg_load_archive_sha, f[1], sha) : CALL(pkg_load_archive, f[1]);
        os_try_end(&tf);
    } else {
        sc_put("A fault");
        g_alloc_fail = 0;
        return;
    }
    g_alloc_fail = 0;
    sc_put("A ");
    if (!ctx) { sc_put("null"); return; }
    sc_put(sha); sc_put(" type="); sc_num(ctx->type); sc_put(" n="); sc_num(ctx->count); sc_put(" len="); sc_num((int64_t)ctx->raw_len);
    for (uint32_t i = 0; i < ctx->count; i++) {
        char out[32] = "x";
        out[1 + u64_to_dec(i, out + 1)] = 0;
        int r = CALL(pkg_extract_entry_to, ctx, &ctx->entries[i], out);
        sc_put(" ["); sc_esc(ctx->entries[i].name); sc_put(" r="); sc_num(r);
        size_t got = 0;
        if (fs_read_file_head(out, g_buf, sizeof g_buf, &got) >= 0) { sc_put(" "); sc_num((int64_t)got); sc_put(" "); sc_num((int64_t)(fnv(g_buf, got) >> 1)); }
        sc_put("]");
    }
    CALLV(pkg_free_archive, ctx);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    os_fault_guard_install();
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[5];
        int n = sc_split(line, f, 5);
        if (!n) continue;
        switch (f[0][0]) {
        case 'M': CALLV(pkg_mkdir_p, n > 1 ? f[1] : ""); sc_put("M"); break;
        case 'W': {
            if (n < 3) continue;
            size_t len = (size_t)num(f[2]);
            for (size_t i = 0; i < len && i < sizeof g_buf; i++) g_buf[i] = (uint8_t)(i * 7 + 3);
            int r = CALL(pkg_write_file, f[1], g_buf, len);
            sc_put("W r="); sc_num(r);
            break;
        }
        case 'X': {
            if (n < 2) continue;
            int r = CALL(pkg_ensure_exec, f[1]);
            FileStat st;
            sc_put("X r="); sc_num(r);
            if (!os_is_err(os_statat(AT_FDCWD, f[1], &st, 0))) { sc_put(" mode="); sc_num(st.mode & 07777); }
            break;
        }
        case 'F': if (n < 2) continue; cmd_manifest(f, n); break;
        case 'A': if (n < 4) continue; cmd_archive(f); break;
        default: continue;
        }
        sc_put("\n");
        sc_flush();
    }
    sc_flush();
    return 0;
}
