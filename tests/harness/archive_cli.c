/* Freestanding harness: the frozen asm archive layer (archive_vfs_reference.s + archive_extract_reference.s, x86_64, ref_ prefix) or
 * src/fs/archive_parse.c + archive_vfs.c (compiled into this unit, paths in AR_SRC1 / AR_SRC2), on the C DirModel stack.
 * argv[1] = ref | c. Script on stdin:
 *   P <file> <t|z|g>   parse a whole file (tar / zip index, or gunzip): the entries (or the gunzipped length and hash); a fault
 *                      inside the parser prints "fault" (the fault guard is installed)
 *   N <dir>            a pane model of dir;   E <name>   arc_enter_model on the visible entry called name;   U   arc_nav_up_model
 *   X <name>           arc_extract_entry of the visible entry: its bytes (hash, length)
 *   L                  the pane listing */
#include "script_cli.h"
#include "duop_arc.h"
#include "duop_pal.h"

int git_refresh(DirModel *m) { (void)m; return 0; }
void git_free_ctx(DirModel *m) { m->git_ctx = nullptr; }

#include AR_SRC1
#include AR_SRC2

#ifdef __x86_64__
extern void ref_arc_parse_tar(ArcCtx *), ref_arc_parse_zip(ArcCtx *);
extern void *ref_arc_ungzip(const uint8_t *, uint64_t, uint64_t *);
extern int ref_arc_is_archive(const char *), ref_arc_enter_model(DirModel *, const FileEntry *), ref_arc_nav_up_model(DirModel *);
extern int ref_arc_extract_entry(DirModel *, const FileEntry *, char *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static DirModel *g_m;
static char g_tmp[PATH_MAX];

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

static uint64_t fnv(const uint8_t *p, size_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull;
    return h >> 1;
}

static void cmd_parse(const char *file, char kind_arg)
{
    volatile char kind = kind_arg;
    ArcCtx *ctx = mem_alloc(sizeof *ctx);
    if (!ctx) return;
    mem_zero(ctx, sizeof *ctx);
    /* kind 'Z': a zip whose buffer starts right after a PROT_NONE page, so a read before the buffer faults */
    uint8_t *volatile guard = nullptr;
    if (kind == 'Z') {
        intptr_t g = os_mmap(nullptr, ARC_MAX_FILE + 4096, PROT_RW, MAP_PRIVATE_ANON, -1, 0);
        if (os_is_err(g) || os_is_err(os_mmap((void *)g, 4096, 0, MAP_PRIVATE_ANON | MAP_FIXED, -1, 0))) { sc_put("P noread"); return; }
        guard = (uint8_t *)g + 4096;
        kind = 'z';
    }
    ctx->raw = guard ? guard : mem_alloc(ARC_MAX_FILE);
    ctx->entries = mem_alloc(ARC_MAX_ENTRIES * sizeof(ArcEntry));
    size_t got = 0;
    if (!ctx->raw || !ctx->entries || fs_read_file_head(file, ctx->raw, ARC_MAX_FILE, &got) < 0) { sc_put("P noread"); return; }
    ctx->raw_len = got;
    mem_zero(ctx->entries, ARC_MAX_ENTRIES * sizeof(ArcEntry));
    sc_put("P");
    volatile uint64_t outlen = 0;
    void *volatile out = nullptr;
    TryFrame f;
    if (os_try_begin(&f) == 0) {
        uint64_t n = 0;
        if (kind == 't') CALLV(arc_parse_tar, ctx);
        else if (kind == 'z') CALLV(arc_parse_zip, ctx);
        else { out = CALL(arc_ungzip, ctx->raw, ctx->raw_len, &n); outlen = n; }
        os_try_end(&f);
    } else {
        sc_put(" fault");
        if (guard) (void)os_munmap_raw(guard - 4096, ARC_MAX_FILE + 4096);
        return;
    }
    if (kind == 'g') {
        sc_put(" gz="); sc_num(out != nullptr); sc_put(" len="); sc_num((int64_t)outlen);
        if (out) { sc_put(" h="); sc_num((int64_t)fnv(out, outlen)); mem_free(out); }
        mem_free(ctx->raw); mem_free(ctx->entries); mem_free(ctx);
        return;
    }
    sc_put(" n="); sc_num(ctx->count);
    for (uint32_t i = 0; i < ctx->count; i++) {
        const ArcEntry *e = &ctx->entries[i];
        sc_put(" ["); sc_esc(e->name); sc_put(" "); sc_num((int64_t)e->off); sc_put(" "); sc_num((int64_t)e->size); sc_put(" ");
        sc_num((int64_t)e->comp_size); sc_put(" "); sc_num(e->method); sc_put(" "); sc_num(e->is_dir); sc_put("]");
    }
    if (guard) (void)os_munmap_raw(guard - 4096, ARC_MAX_FILE + 4096);
    else mem_free(ctx->raw);
    mem_free(ctx->entries); mem_free(ctx);
}

static FileEntry *find_visible(const char *name)
{
    intptr_t i = DirModel_find_by_name(g_m, name);
    return i < 0 ? nullptr : DirModel_get_entry(g_m, i);
}

static void put_listing(void)
{
    sc_put(" path="); sc_esc(g_m->path); sc_put(" vm="); sc_num(g_m->virtual_mode); sc_put(" n="); sc_num((int64_t)g_m->count);
    sc_put(" sub="); sc_esc(g_m->arc_ctx ? ((ArcCtx *)g_m->arc_ctx)->sub : "-");
    for (uint64_t i = 0; i < g_m->count; i++) {
        const FileEntry *e = &g_m->entries[g_m->order[i]];
        sc_put(" "); sc_esc(g_m->name_pool + e->name_off); sc_put(":"); sc_num(e->flags & (FE_IS_DIR | FE_IS_PARENT)); sc_put(":"); sc_num(e->size);
    }
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    os_fault_guard_install();
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[4];
        int n = sc_split(line, f, 4);
        if (!n) continue;
        switch (f[0][0]) {
        case 'P': if (n < 3) continue; cmd_parse(f[1], f[2][0]); break;
        case 'N': if (g_m) Object_free(&g_m->base); g_m = DirModel_new(f[1]); if (g_m) { while (g_m->is_loading) (void)DirModel_step_load(g_m, 0); }
                  sc_put("N"); if (g_m) put_listing(); break;
        case 'E': { if (!g_m) continue; FileEntry *e = n > 1 ? find_visible(f[1]) : nullptr; if (e) DirModel_ensure_entry_stat(g_m, e); int r = CALL(arc_enter_model, g_m, e);
                    sc_put("E r="); sc_num(r); put_listing(); break; }
        case 'U': { if (!g_m) continue; int r = CALL(arc_nav_up_model, g_m); while (g_m->is_loading) (void)DirModel_step_load(g_m, 0);
                    sc_put("U r="); sc_num(r); put_listing(); break; }
        case 'X': {
            if (!g_m || n < 2) continue;
            int r = CALL(arc_extract_entry, g_m, find_visible(f[1]), g_tmp);
            sc_put("X r="); sc_num(r);
            if (r == 0) {
                static uint8_t buf[1 << 22];
                size_t got = 0;
                (void)fs_read_file_head(g_tmp, buf, sizeof buf, &got);
                sc_put(" len="); sc_num((int64_t)got); sc_put(" h="); sc_num((int64_t)fnv(buf, got));
                (void)os_unlinkat(AT_FDCWD, g_tmp, 0);
            }
            break;
        }
        case 'L': if (!g_m) continue; sc_put("L"); put_listing(); break;
        default: continue;
        }
        sc_put("\n");
        sc_flush();
    }
    if (g_m) Object_free(&g_m->base);
    sc_flush();
    return 0;
}
