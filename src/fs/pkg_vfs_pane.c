/* src/fs/pkg_vfs_pane.c - a VFS provider package as a browsable pane (DirModel virtual_mode 3) and files read through it
 * (freestanding C23; replaces pkg_vfs_pane.s, kept as tests/harness/pkg_vfs_pane_reference.s).
 *
 * The provider of <scheme>://... is the installed package with kind = vfs and vfs_scheme = <scheme>. `<exec> LIST <uri>` prints
 * one "name<TAB>size<TAB>mtime[<TAB>d]" line per entry; `<exec> READ <uri> <tmp file>` writes the file. A call succeeds only when
 * the provider exits with status 0; 1.5 s without output stops it (killed), so a hung provider can never freeze the UI. */
#include "duop_pkg.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define PKVP_MANIFEST_MAX 4096
#define PKVP_DIRBUF 16384
#define PKVP_SILENCE_MS 1500
#define PKVP_LIST_FIRST 65536
#define PKVP_LIST_MAX (8u << 20)   /* a listing beyond 8 MiB is refused, never cut */

typedef struct PkvpInfo { char kind[32], scheme[64], exec[64]; } PkvpInfo;
typedef struct PkvpOut { char *buf; size_t len, cap, max; } PkvpOut;   /* buf NULL: the output is drained and dropped */

static void pkvp_trim_cp(const char *s, const char *e, char *dst, int cap)
{
    while (s < e && (*s == ' ' || *s == '\t')) s++;
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r')) e--;
    int n = 0;
    while (n < cap - 1 && s < e) dst[n++] = *s++;
    dst[n] = 0;
}

static void pkvp_parse(const char *buf, int len, PkvpInfo *out)
{
    out->kind[0] = out->scheme[0] = out->exec[0] = 0;
    const char *end = buf + len;
    for (const char *line = buf; line < end;) {
        const char *eol = line, *eq;
        while (eol < end && *eol != '\n') eol++;
        for (eq = line; eq < eol && *eq != '='; eq++) {}
        if (eq < eol) {
            char key[64];
            pkvp_trim_cp(line, eq, key, sizeof key);
            if (!str_cmp(key, "kind")) pkvp_trim_cp(eq + 1, eol, out->kind, sizeof out->kind);
            else if (!str_cmp(key, "vfs_scheme")) pkvp_trim_cp(eq + 1, eol, out->scheme, sizeof out->scheme);
            else if (!str_cmp(key, "exec")) pkvp_trim_cp(eq + 1, eol, out->exec, sizeof out->exec);
        }
        line = eol + 1;
    }
}

/* the exec of dir's package when it is the vfs provider of uri (scheme "://" prefix): true with exe_out = <dir>/<exec> */
static bool pkvp_match(const char *dir, const char *uri, char *man, char *exe_out)
{
    PkvpInfo in;
    size_t len, sl;
    if (path_join(exe_out, dir, "manifest.ini", PATH_MAX) < 0 || fs_read_file_head(exe_out, man, PKVP_MANIFEST_MAX, &len) < 0) return false;
    pkvp_parse(man, (int)len, &in);
    if (str_cmp(in.kind, "vfs") || !in.scheme[0] || !str_starts_with(uri, in.scheme)) return false;
    sl = str_len(in.scheme);
    const char *rel = uri[sl] == ':' && uri[sl + 1] == '/' && uri[sl + 2] == '/' ? pkm_safe_relpath(in.exec) : nullptr;
    return rel && path_join(exe_out, dir, rel, PATH_MAX) >= 0;
}

int pkg_vfs_find_by_uri(char **envp, const char *uri, char *exe_out)
{
    char *mem = mem_alloc(2 * PATH_MAX + PKVP_DIRBUF + PKVP_MANIFEST_MAX);
    if (!mem) return -1;
    char *root = mem, *dir = mem + PATH_MAX, *dents = mem + 2 * PATH_MAX, *man = dents + PKVP_DIRBUF;
    bool found = false;
    pkg_get_root(envp, root, PATH_MAX);
    intptr_t fd = root[0] ? os_openat(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0) : -ENOENT;
    for (intptr_t got; !os_is_err(fd) && !found && (got = os_dir_read((int)fd, dents, PKVP_DIRBUF)) > 0;) {
        size_t pos = 0;
        uint8_t type;
        for (const char *nm; !found && (nm = os_dir_next_ex(dents, (size_t)got, &pos, &type));)
            found = str_cmp(nm, ".") && str_cmp(nm, "..") && path_join(dir, root, nm, PATH_MAX) >= 0 && pkvp_match(dir, uri, man, exe_out);
    }
    if (!os_is_err(fd)) (void)os_close((int)fd);
    mem_free(mem);
    return found ? 0 : -1;
}

/* reads the provider's stdout to EOF into o (growing to o->max); false on silence, overflow, OOM or a read error */
static bool pkvp_pump(int fd, PkvpOut *o)
{
    static char drain[4096];
    for (;;) {
        int pr = os_poll_in(fd, PKVP_SILENCE_MS);
        if (pr == -EINTR) continue;
        if (pr <= 0) return false;
        if (o->buf && o->len == o->cap) {
            size_t nc = o->cap * 2 > o->max ? o->max : o->cap * 2;
            char *nb = nc > o->cap ? mem_realloc(o->buf, nc) : nullptr;
            if (!nb) return false;                                     /* beyond the limit or OOM: refused */
            o->buf = nb;
            o->cap = nc;
        }
        intptr_t n = o->buf ? os_read(fd, o->buf + o->len, o->cap - o->len) : os_read(fd, drain, sizeof drain);
        if (n == -EINTR) continue;
        if (n == 0) return true;
        if (n < 0) return false;
        if (o->buf) o->len += (size_t)n;
    }
}

/* `<exe> <cmd> <uri> [arg4]` with stdout captured: 0 when it ran to EOF and exited with status 0, else -1 (a stuck one is killed) */
static int pkvp_run(const char *exe, const char *cmd, const char *uri, const char *arg4, char **envp, PkvpOut *o)
{
    int fds[2];
    if (pkg_ensure_exec(exe) < 0 || os_is_err(os_pipe2(fds, O_CLOEXEC))) return -1;
    intptr_t pid = os_fork();
    if (os_is_err(pid)) {
        (void)os_close(fds[0]);                                    /* fault-checked */
        (void)os_close(fds[1]);                                    /* fault-checked */
        return -1;
    }
    if (pid == 0) {
        (void)os_close(fds[0]);                                    /* fault-checked */
        if (!os_is_err(os_dup2(fds[1], 1))) {
            (void)os_close(fds[1]);                                /* fault-checked */
            os_sig_reset_pipe();
            os_mark_child_forked();
            const char *argv[] = {exe, cmd, uri, arg4, nullptr};
            (void)os_execve(exe, (char *const *)argv, envp);
        }
        os_exit(127);
    }
    (void)os_close(fds[1]);                                        /* fault-checked */
    bool done = pkvp_pump(fds[0], o);
    (void)os_close(fds[0]);                                        /* fault-checked */
    if (!done) (void)os_kill((int)pid, SIGKILL);                   /* fault-checked: a stuck provider is stopped */
    int status = 0;
    intptr_t w;
    while ((w = os_wait4((int)pid, &status, 0, nullptr)) == -EINTR) {}
    return done && !os_is_err(w) && status == 0 ? 0 : -1;
}

static int64_t pkvp_dec(const char **p, const char *end)            /* decimal digits, wrapping like the asm on overflow */
{
    uint64_t v = 0;
    for (; *p < end && **p >= '0' && **p <= '9'; (*p)++) v = v * 10 + (uint64_t)(**p - '0');
    return (int64_t)v;
}

/* one "name<TAB>size<TAB>mtime[<TAB>d]" line appended (CRs in the name dropped, at most 255 bytes): 0, or -1 when the model is full */
static int pkvp_add_line(DirModel *m, const char *p, const char *eol)
{
    char name[256];
    int n = 0;
    for (; p < eol && *p != '\t'; p++)
        if (*p != '\r' && n < 255) name[n++] = *p;
    if (p < eol) p++;
    name[n] = 0;
    if (!n) return 0;
    FileStat st;
    mem_zero(&st, sizeof st);
    st.size = pkvp_dec(&p, eol);
    st.mode = S_IFREG | 0644;
    if (p < eol && *p == '\t') {
        p++;
        st.mtime = pkvp_dec(&p, eol);
        if (p < eol && *p == '\t' && p + 1 < eol && p[1] == 'd') st.mode = S_IFDIR | 0755;
    }
    return ds_append_entry(m, name, &st) < 0 ? -1 : 0;
}

int pkg_vfs_load_dir(char **envp, DirModel *model, const char *uri)
{
    char exe[PATH_MAX];
    PkvpOut o = {mem_alloc(PKVP_LIST_FIRST), 0, PKVP_LIST_FIRST, PKVP_LIST_MAX};
    int r = -1;
    if (!o.buf || pkg_vfs_find_by_uri(envp, uri, exe) != 0 || pkvp_run(exe, "LIST", uri, nullptr, envp, &o) != 0) goto out;
    if (model->virtual_mode != 3) {                                    /* entering: remember the real directory */
        char *orig = mem_alloc(PATH_MAX);
        if (!orig) goto out;
        (void)str_copy(orig, model->path, PATH_MAX);
        model->arc_ctx = orig;
    }
    DirModel_cancel_load(model);
    model->raw_count = model->count = model->name_used = model->total_bytes = 0;
    model->dir_count = model->file_count = 0;
    model->virtual_mode = 3;
    model->stats_complete = 1;
    (void)str_copy(model->path, uri, PATH_MAX);
    if (ds_append_parent(model) < 0) goto out;
    for (const char *p = o.buf, *end = o.buf + o.len; p < end;) {
        const char *eol = p;
        while (eol < end && *eol != '\n') eol++;
        if (pkvp_add_line(model, p, eol) < 0) goto out;
        p = eol + 1;
    }
    DirModel_sort(model);
    r = 0;
out:
    mem_free(o.buf);
    return r;
}

int pkg_vfs_parent_uri(const char *uri, char *out, int cap)
{
    (void)str_copy(out, uri, (size_t)cap);
    size_t s = 0;
    while (out[s] && !(out[s] == ':' && out[s + 1] == '/' && out[s + 2] == '/')) s++;
    if (!out[s] || !out[s + 3]) return 0;                              /* no "://", or already the root: leave the VFS */
    s += 3;
    size_t e = s + str_len(out + s);
    while (--e > s)
        if (out[e] == '/') { out[e] = 0; return 1; }
    out[s] = 0;
    return 1;
}

int pkg_vfs_read_uri(char **envp, const char *uri, char *out_tmp_path, int cap)
{
    char exe[PATH_MAX];
    PkvpOut drain = {nullptr, 0, 0, 0};
    if (pkg_vfs_find_by_uri(envp, uri, exe) != 0 || tmp_make_path("vfs_view", "", out_tmp_path, cap) < 0) return -1;
    if (pkvp_run(exe, "READ", uri, out_tmp_path, envp, &drain) == 0) return 0;
    (void)os_unlinkat(AT_FDCWD, out_tmp_path, 0);                       /* no half-written view file left behind */
    return -1;
}
