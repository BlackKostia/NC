/* Freestanding harness: the frozen asm copy engine (file_ops_copy_reference.s + file_ops_copy_at_reference.s, x86_64, ref_ prefix)
 * or src/fs/file_ops_copy.c (compiled into this unit, path in FOC_SRC). argv = <ref|c> <base dir>; "@" at the start of a path
 * stands for the base dir (identical trees for the two runs). Stand-ins: fs_progress_* count items / bytes and cancel on request;
 * g_fs_progress says whether we play the background worker; fo_resolve_eexist_open applies a scripted conflict policy (the real
 * one asks the UI). Script on stdin:
 *   R <src> <dst>   fs_copy_recursive     F <src> <dst>   fs_copy_file
 *   W <0|1>         UI process / background worker     C <k>   the k-th cancel poll from now answers "cancel" (0 never)
 *   P <s|x|o|i|e>   conflict policy: skip, same file (-9999), crash-safe overwrite (temp file), in place (O_TRUNC), -EIO
 *   S <nr> <errno>  (x86_64) seccomp: system call nr fails with errno from now on (e.g. fsync 74 -> EIO) */
#include "script_cli.h"
#include "duop_task.h"
#include "duop_pal.h"

TaskShared *g_fs_progress;
static uint64_t g_items, g_bytes, g_begins;
static int64_t g_cancel_in;
static char g_policy = 's';

void fs_progress_begin(const char *path) { (void)path; g_begins++; }
void fs_progress_item(void) { g_items++; }
void fs_progress_bytes(uint64_t n) { g_bytes += n; }
int fs_progress_cancelled(void) { return g_cancel_in > 0 && --g_cancel_in == 0; }

FoOpenResult fo_resolve_eexist_open(int dst_dfd, const char *dst_rel, const FileStat *src_st, char *out_ren);
FoOpenResult fo_resolve_eexist_open(int dst_dfd, const char *dst_rel, const FileStat *src_st, char *out_ren)
{
    FileStat dst;
    if (os_statat(dst_dfd, dst_rel, &dst, 0) < 0) return (FoOpenResult){-ENOENT, 0};
    switch (g_policy) {
    case 's': return (FoOpenResult){-2, 0};
    case 'x': return (FoOpenResult){-9999, 0};
    case 'e': return (FoOpenResult){-EIO, 0};
    case 'i': return (FoOpenResult){os_openat(dst_dfd, dst_rel, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0), 0};
    default: return fo_open_overwrite(dst_dfd, dst_rel, dst.mode, src_st->mode & 07777, out_ren);
    }
}

#include FOC_SRC

#ifdef __x86_64__
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

extern intptr_t ref_fs_copy_recursive(const char *, const char *);
extern intptr_t ref_fs_copy_file(const char *, const char *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static char g_base[PATH_MAX], g_p1[PATH_MAX], g_p2[PATH_MAX];
static TaskShared g_worker_token;

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
        case 'R': case 'F': {
            if (n < 3) continue;
            g_items = g_bytes = g_begins = 0;
            intptr_t r = f[0][0] == 'R' ? CALL(fs_copy_recursive, at(f[1], g_p1), at(f[2], g_p2)) : CALL(fs_copy_file, at(f[1], g_p1), at(f[2], g_p2));
            sc_put(f[0][0] == 'R' ? "R r=" : "F r="); sc_num(r);
            sc_put(" items="); sc_num((int64_t)g_items); sc_put(" bytes="); sc_num((int64_t)g_bytes); sc_put(" begins="); sc_num((int64_t)g_begins);
            break;
        }
        case 'W': g_fs_progress = num(f[1]) ? &g_worker_token : nullptr; continue;
        case 'C': g_cancel_in = num(f[1]); continue;
        case 'P': g_policy = f[1][0]; continue;
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
