/* Freestanding harness: frozen asm trash / undo code (ref_ prefix) next to src/fs/trash_*.c. One implementation per run,
 * driven by a script on stdin so that the two runs can use separate (but identically built) directory trees:
 *   I <info> <hex orig>     tu_write_info                      H <cap> <xdg|-> <home|-> [noenv]   tu_get_data_home
 *   D <data_home>           tu_mkdir_p_base                    Q <data_home> <hex base>             tu_pick_unique
 *   E <NAME=value>          add to the envp of T               T <src>                            trash_move_file + undo_push
 *   P <kind> <orig> <cur> <info|->   undo_push                 U                                  undo_pop_and_apply
 *   M <rename|copy|delete> <0|-errno>   force the result of the file-operation stand-ins below (0: do the real thing)
 *   W <path>  create / overwrite a file     R <path>  remove     V <old> <new>  rename (edits between calls) */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#ifndef REF
#define REF 0
#endif
extern int ref_tu_write_info(const char *, const char *);
extern void ref_tu_get_data_home(const char *const *, char *, size_t);
extern void ref_tu_mkdir_p_base(const char *);
extern int ref_tu_pick_unique(const char *, const char *, char *, char *);
extern int ref_trash_move_file(const char *, const char *const *, char *, char *);
extern void ref_undo_push(int, const char *, const char *, const char *);
extern int ref_undo_pop_and_apply(void);

static int g_force_rename, g_force_copy, g_force_delete;

static int fs_delete_recursive_real(const char *path)
{
    intptr_t r = os_unlinkat(AT_FDCWD, path, 0);
    return r < 0 ? (int)os_unlinkat(AT_FDCWD, path, AT_REMOVEDIR) : 0;
}

/* stand-ins for the copy engine (file_ops*.s): enough to move regular files and empty directories */
intptr_t fs_rename_noreplace(const char *o, const char *n)
{
    if (g_force_rename) return g_force_rename;
    return os_renameat2(AT_FDCWD, o, AT_FDCWD, n, RENAME_NOREPLACE);
}

intptr_t fs_copy_recursive(const char *src, const char *dst)
{
    if (g_force_copy) return g_force_copy;
    FileStat st;
    if (os_statat(AT_FDCWD, src, &st, 0) < 0) return -ENOENT;
    if ((st.mode & S_IFMT) != S_IFREG) return -21;
    intptr_t in = os_openat(AT_FDCWD, src, O_RDONLY, 0), out = os_openat(AT_FDCWD, dst, O_WRONLY | O_CREAT | O_EXCL, st.mode & 0777);
    if (in < 0 || out < 0) return in < 0 ? (int)in : (int)out;
    char buf[4096];
    intptr_t n;
    while ((n = os_read((int)in, buf, sizeof buf)) > 0) (void)os_write((int)out, buf, (size_t)n);
    os_close((int)in);
    os_close((int)out);
    return 0;
}

int fs_delete_recursive(const char *path)
{
    return g_force_delete ? g_force_delete : fs_delete_recursive_real(path);
}

static char g_out[1 << 16];
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

static char *field(char **p)                                 /* next tab-separated field of the current line ("" when exhausted) */
{
    char *s = *p;
    while (**p && **p != '\t') (*p)++;
    if (**p) *(*p)++ = 0;
    return s;
}

static void unhex(char *s)                                   /* in-place "6162" -> "ab" so that scripts can carry any byte but NUL */
{
    char *o = s;
    for (; s[0] && s[1]; s += 2) *o++ = (char)(((s[0] > '9' ? (s[0] | 32) - 'a' + 10 : s[0] - '0') << 4) | (s[1] > '9' ? (s[1] | 32) - 'a' + 10 : s[1] - '0'));
    *o = 0;
}

static int to_int(const char *s)
{
    bool neg = *s == '-';
    int v = 0;
    for (s += neg; *s >= '0' && *s <= '9'; s++) v = v * 10 + (*s - '0');
    return neg ? -v : v;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    bool ref = !str_cmp(argv[1], "ref");
    static char in[1 << 20], files[PATH_MAX], info[PATH_MAX], big[PATH_MAX + 8];
    static const char *env[16];
    int env_n = 0;
    size_t n = 0;
    intptr_t r;
    while (n < sizeof in - 1 && (r = os_read(0, in + n, sizeof in - 1 - n)) > 0) n += (size_t)r;
    in[n] = 0;
    for (char *line = in; *line;) {
        char *eol = line;
        while (*eol && *eol != '\n') eol++;
        char *next = *eol ? eol + 1 : eol;
        *eol = 0;
        char op = *line;
        char *p = line[1] ? line + 2 : line + 1;
        char *a = field(&p), *b = field(&p), *c = field(&p), *d = field(&p);
        files[0] = info[0] = 0;
        switch (op) {
        case 'I': unhex(b); num(ref ? ref_tu_write_info(a, b) : tu_write_info(a, b)); break;
        case 'H': {
            const char *e[3];
            int k = 0;
            static char xdg[PATH_MAX + 32], home[PATH_MAX + 32];
            if (str_cmp(b, "-")) { str_copy(xdg, "XDG_DATA_HOME=", sizeof xdg); str_cat(xdg, b, sizeof xdg); e[k++] = xdg; }
            if (str_cmp(c, "-")) { str_copy(home, "HOME=", sizeof home); str_cat(home, c, sizeof home); e[k++] = home; }
            e[k] = nullptr;
            for (size_t i = 0; i < sizeof big; i++) big[i] = (char)0x7F;
            size_t cap = (size_t)to_int(a);
            if (ref) ref_tu_get_data_home(*d ? nullptr : e, big, cap); else tu_get_data_home(*d ? nullptr : e, big, cap);
            put("["); put(big); put("] guard="); num((uint8_t)big[cap]); break;
        }
        case 'D': if (ref) ref_tu_mkdir_p_base(a); else tu_mkdir_p_base(a); put("ok"); break;
        case 'Q': unhex(b); num(ref ? ref_tu_pick_unique(a, b, files, info) : tu_pick_unique(a, b, files, info)); put(" "); put(files); put(" "); put(info); break;
        case 'E': if (env_n < 14) { env[env_n++] = a; env[env_n] = nullptr; } put("env"); break;
        case 'T': {                                          /* like App_cmd_trash: a successful move is pushed on the undo stack */
            int rc = ref ? ref_trash_move_file(a, env, files, info) : trash_move_file(a, env, files, info);
            num(rc); put(" "); put(files); put(" "); put(info);
            if (rc >= 0) { if (ref) ref_undo_push(UNDO_TRASH, a, files, info); else undo_push(UNDO_TRASH, a, files, info); }
            break;
        }
        case 'P': if (ref) ref_undo_push(to_int(a), b, c, str_cmp(d, "-") ? d : nullptr); else undo_push(to_int(a), b, c, str_cmp(d, "-") ? d : nullptr); put("pushed"); break;
        case 'U': num(ref ? ref_undo_pop_and_apply() : undo_pop_and_apply()); break;
        case 'W': { intptr_t f = os_openat(AT_FDCWD, a, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (f >= 0) { (void)os_write((int)f, "in the way", 10); os_close((int)f); } put("write"); break; }
        case 'R': (void)fs_delete_recursive_real(a); put("rm"); break;
        case 'V': num(os_renameat2(AT_FDCWD, a, AT_FDCWD, b, 0)); break;
        case 'M': {
            int v = to_int(b);
            if (!str_cmp(a, "rename")) g_force_rename = v; else if (!str_cmp(a, "copy")) g_force_copy = v; else g_force_delete = v;
            put("mode"); break;
        }
        }
        put("\n");
        line = next;
    }
    flush();
    return 0;
}
