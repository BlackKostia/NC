/* Freestanding harness: the frozen asm delete / move / read-head (file_ops_delete_reference.s, x86_64, ref_ prefix) or
 * src/fs/file_ops_delete.c (compiled into this unit, path in FOD_SRC); the C copy engine does the cross-file-system part of a move.
 * argv = <ref|c> <base dir>; "@" at the start of a path stands for the base dir. Stand-ins: fs_progress_* count items / begins
 * and cancel on request; g_fs_progress says whether we play the background worker; fo_move_check_conflict and
 * fo_resolve_eexist_open apply scripted policies (the real ones ask the UI). Script on stdin:
 *   D <path>              fs_delete_recursive       M <src> <dst>   fs_move_recursive       H <path> <max>   fs_read_file_head
 *   W <0|1>               UI process / background worker            C <k>   the k-th cancel poll from now answers "cancel"
 *   P <o|s|r|e>           move conflict policy: overwrite, skip, rename to "<dst>.renamed", -EIO
 *   K <s|o>               copy conflict policy of the EXDEV path: skip (sets g_copy_had_skip) / overwrite through a temp file
 *   S <nr> <errno>        (x86_64) seccomp: system call nr fails with errno from now on (renameat2 316 -> EXDEV 18) */
#include "script_cli.h"
#include "duop_task.h"
#include "duop_pal.h"

TaskShared *g_fs_progress;
int g_copy_had_skip;
static uint64_t g_items, g_begins;
static int64_t g_cancel_in;
static char g_move_policy = 'o', g_copy_policy = 's';
static TaskShared g_worker_token;

void fs_progress_begin(const char *path) { (void)path; g_begins++; }
void fs_progress_item(void) { g_items++; }
void fs_progress_bytes(uint64_t n) { (void)n; }
int fs_progress_cancelled(void) { return g_fs_progress && g_cancel_in > 0 && --g_cancel_in == 0; }

intptr_t fo_move_check_conflict(const char *src, const char *dst, char *out_ren);
intptr_t fo_move_check_conflict(const char *src, const char *dst, char *out_ren)
{
    (void)src;
    switch (g_move_policy) {
    case 's': return 2;
    case 'e': return -EIO;
    case 'r': { size_t n = str_copy(out_ren, dst, PATH_MAX); (void)str_copy(out_ren + n, ".renamed", PATH_MAX - n); return 3; }
    default: return 1;
    }
}

FoOpenResult fo_resolve_eexist_open(int dst_dfd, const char *dst_rel, const FileStat *src_st, char *out_ren);
FoOpenResult fo_resolve_eexist_open(int dst_dfd, const char *dst_rel, const FileStat *src_st, char *out_ren)
{
    FileStat dst;
    if (os_statat(dst_dfd, dst_rel, &dst, 0) < 0) return (FoOpenResult){-ENOENT, 0};
    if (g_copy_policy == 's') { g_copy_had_skip = 1; return (FoOpenResult){-2, 0}; }
    return fo_open_overwrite(dst_dfd, dst_rel, dst.mode, src_st->mode & 07777, out_ren);
}

#include FOD_SRC

#ifdef __x86_64__
extern intptr_t ref_fs_delete_recursive(const char *);
extern intptr_t ref_fs_move_recursive(const char *, const char *);
extern intptr_t ref_fs_read_file_head(const char *, void *, size_t, size_t *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))

static long sys5(long nr, long a, long b, long c, long d)
{
    long ret;
    register long r10 __asm__("r10") = d, r8 __asm__("r8") = 0, r9 __asm__("r9") = 0;   /* prctl wants the unused args 0 */
    __asm__ volatile("syscall" : "=a"(ret) : "a"(nr), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

static void cmd_seccomp(uint32_t nr, uint32_t err)
{
    struct { uint16_t code; uint8_t jt, jf; uint32_t k; } prog[] = {
        {0x20, 0, 0, 0}, {0x15, 0, 1, nr}, {0x06, 0, 0, 0x00050000u | err}, {0x06, 0, 0, 0x7fff0000u},
    };
    struct { uint16_t len; void *filter; } fprog = {4, prog};
    long a = sys5(157, 38, 1, 0, 0), b = sys5(317, 1, 0, (long)&fprog, 0);
    sc_put("S "); sc_num(a); sc_put(" "); sc_num(b); sc_put("\n");
}
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static char g_base[PATH_MAX], g_p1[PATH_MAX], g_p2[PATH_MAX];
static uint8_t g_buf[70000];

static const char *at(const char *p, char *buf)
{
    if (p[0] != '@') return p;
    size_t n = str_copy(buf, g_base, PATH_MAX);
    (void)str_copy(buf + n, p + 1, PATH_MAX - n);
    return buf;
}

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

static int64_t num(const char *s) { int64_t v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0'); return v; }

static void counts(void) { sc_put(" items="); sc_num((int64_t)g_items); sc_put(" begins="); sc_num((int64_t)g_begins); g_items = g_begins = 0; }

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 3) return 2;
    g_ref = argv[1][0] == 'r';
    (void)str_copy(g_base, argv[2], PATH_MAX);
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[4];
        int n = sc_split(line, f, 4);
        if (!n) continue;
        switch (f[0][0]) {
        case 'D': sc_put("D r="); sc_num(CALL(fs_delete_recursive, at(f[1], g_p1))); counts(); break;
        case 'M': if (n < 3) continue; sc_put("M r="); sc_num(CALL(fs_move_recursive, at(f[1], g_p1), at(f[2], g_p2))); sc_put(" skip="); sc_num(g_copy_had_skip); sc_put(" wk="); sc_num(g_fs_progress != nullptr); counts(); break;
        case 'H': {
            if (n < 3) continue;
            size_t got = 777, max = (size_t)num(f[2]);
            if (max > sizeof g_buf) max = sizeof g_buf;
            for (size_t i = 0; i < sizeof g_buf; i++) g_buf[i] = 0xA5;
            intptr_t r = CALL(fs_read_file_head, at(f[1], g_p1), g_buf, max, n > 3 ? nullptr : &got);
            uint64_t h = 1469598103934665603ull;
            for (size_t i = 0; i < sizeof g_buf; i++) h = (h ^ g_buf[i]) * 1099511628211ull;
            sc_put("H r="); sc_num(r); sc_put(" got="); sc_num((int64_t)got); sc_put(" h="); sc_num((int64_t)(h >> 1));
            break;
        }
        case 'W': g_fs_progress = num(f[1]) ? &g_worker_token : nullptr; continue;
        case 'C': g_cancel_in = num(f[1]); continue;
        case 'P': g_move_policy = f[1][0]; continue;
        case 'K': g_copy_policy = f[1][0]; continue;
#ifdef __x86_64__
        case 'S': if (n >= 3) cmd_seccomp((uint32_t)num(f[1]), (uint32_t)num(f[2])); continue;
#endif
        default: continue;
        }
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
