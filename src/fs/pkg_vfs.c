/* src/fs/pkg_vfs.c - out-of-process VFS providers: `duop pkg vfs-list <scheme>://...` runs the exec of the installed package with
 * kind = vfs and vfs_scheme = <scheme> as `<exec> LIST <uri>` and copies its output to stdout (freestanding C23; replaces
 * pkg_vfs.s, kept as tests/harness/pkg_vfs_reference.s).
 *
 * The provider ends its listing by exiting; one second without output ends it too, and then the provider is killed: a hung helper
 * can never hang duop. The result is 0 only when the provider exited with status 0. */
#include "duop_pkg.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define PKV_SCHEME_MAX 63          /* scheme characters before ':' (the vfs_scheme field holds 63) */
#define PKV_MANIFEST_MAX 4096
#define PKV_DIRBUF 16384
#define PKV_SILENCE_MS 1000

typedef struct PkvInfo { char kind[32], scheme[64], exec[64]; } PkvInfo;

static void pkv_trim_cp(const char *s, const char *e, char *dst, int cap)
{
    while (s < e && (*s == ' ' || *s == '\t')) s++;
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r')) e--;
    int n = 0;
    while (n < cap - 1 && s < e) dst[n++] = *s++;
    dst[n] = 0;
}

static void pkv_parse(const char *buf, int len, PkvInfo *out)
{
    out->kind[0] = out->scheme[0] = out->exec[0] = 0;
    const char *end = buf + len;
    for (const char *line = buf; line < end;) {
        const char *eol = line, *eq;
        while (eol < end && *eol != '\n') eol++;
        for (eq = line; eq < eol && *eq != '='; eq++) {}
        if (eq < eol) {
            char key[64];
            pkv_trim_cp(line, eq, key, sizeof key);
            if (!str_cmp(key, "kind")) pkv_trim_cp(eq + 1, eol, out->kind, sizeof out->kind);
            else if (!str_cmp(key, "vfs_scheme")) pkv_trim_cp(eq + 1, eol, out->scheme, sizeof out->scheme);
            else if (!str_cmp(key, "exec")) pkv_trim_cp(eq + 1, eol, out->exec, sizeof out->exec);
        }
        line = eol + 1;
    }
}

/* copies the provider's output to stdout until EOF or PKV_SILENCE_MS of silence; false on silence or a write error */
static bool pkv_pump(int fd)
{
    static char buf[4096];
    for (;;) {
        int pr = os_poll_in(fd, PKV_SILENCE_MS);
        if (pr == -EINTR) continue;
        if (pr <= 0) return false;
        intptr_t n = os_read(fd, buf, sizeof buf);
        if (n == -EINTR) continue;
        if (n == 0) return true;
        if (n < 0 || sys_write_all(1, buf, (size_t)n) < 0) return false;
    }
}

static int pkv_exec_list(const char *exe, const char *uri, char **envp)
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
            const char *argv[] = {exe, "LIST", uri, nullptr};
            (void)os_execve(exe, (char *const *)argv, envp);
        }
        os_exit(127);
    }
    (void)os_close(fds[1]);                                        /* fault-checked */
    bool done = pkv_pump(fds[0]);
    (void)os_close(fds[0]);                                        /* fault-checked */
    if (!done) (void)os_kill((int)pid, SIGKILL);                   /* fault-checked: a silent provider is stopped */
    int status = 0;
    intptr_t w;
    while ((w = os_wait4((int)pid, &status, 0, nullptr)) == -EINTR) {}
    return done && !os_is_err(w) && status == 0 ? 0 : -1;
}

/* <dir>/<exec> of the first package with kind = vfs and vfs_scheme = scheme and a safe exec, into exe: true when found */
static bool pkv_find(const char *root, const char *scheme, char *mem, char *exe)
{
    char *dir = mem, *dents = mem + PATH_MAX, *man = dents + PKV_DIRBUF;
    intptr_t fd = os_openat(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (os_is_err(fd)) return false;
    bool found = false;
    for (intptr_t got; !found && (got = os_dir_read((int)fd, dents, PKV_DIRBUF)) > 0;) {
        size_t pos = 0, len;
        uint8_t type;
        for (const char *name; !found && (name = os_dir_next_ex(dents, (size_t)got, &pos, &type));) {
            PkvInfo info;
            if (name[0] == '.' || path_join(dir, root, name, PATH_MAX) < 0 || path_join(exe, dir, "manifest.ini", PATH_MAX) < 0 ||
                fs_read_file_head(exe, man, PKV_MANIFEST_MAX, &len) < 0)
                continue;
            pkv_parse(man, (int)len, &info);
            const char *rel = !str_cmp(info.kind, "vfs") && !str_cmp(info.scheme, scheme) ? pkm_safe_relpath(info.exec) : nullptr;
            found = rel && path_join(exe, dir, rel, PATH_MAX) >= 0;
        }
    }
    (void)os_close((int)fd);
    return found;
}

int pkg_vfs_list_stdout(char **envp, const char *uri)
{
    char scheme[PKV_SCHEME_MAX + 1];
    size_t n = 0;
    while (n < PKV_SCHEME_MAX - 1 && uri[n] && uri[n] != ':') { scheme[n] = uri[n]; n++; }
    if (uri[n] != ':' || !n) return -1;                            /* no scheme: never the package without vfs_scheme */
    scheme[n] = 0;
    char *mem = mem_alloc(3 * PATH_MAX + PKV_DIRBUF + PKV_MANIFEST_MAX);
    if (!mem) return -1;
    char *root = mem, *exe = mem + PATH_MAX;
    int r = -1;
    pkg_get_root(envp, root, PATH_MAX);
    if (root[0] && pkv_find(root, scheme, mem + 2 * PATH_MAX, exe)) r = pkv_exec_list(exe, uri, envp);
    mem_free(mem);
    return r;
}
