/* src/fs/pkg_preview.c - external previewers: the package whose preview_ext lists a suffix of the file runs as
 * `<preview_exec> <file>` and its stdout is the preview (freestanding C23; replaces pkg_preview.s, kept as
 * tests/harness/pkg_preview_reference.s). The previewer gets no new privileges; 350 ms without output, or a full buffer, stops it
 * (killed), so the preview helper never waits on a stuck previewer. */
#include "duop_pkg.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define PKPV_MANIFEST_MAX 4096
#define PKPV_DIRBUF 16384
#define PKPV_SILENCE_MS 350

static void pkpv_trim_cp(const char *s, const char *e, char *dst, int cap)
{
    while (s < e && (*s == ' ' || *s == '\t')) s++;
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r')) e--;
    int n = 0;
    while (n < cap - 1 && s < e) dst[n++] = *s++;
    dst[n] = 0;
}

static void pkpv_parse(const char *buf, int len, char *pext, char *pexec)
{
    pext[0] = pexec[0] = 0;
    const char *end = buf + len;
    for (const char *line = buf; line < end;) {
        const char *eol = line, *eq;
        while (eol < end && *eol != '\n') eol++;
        for (eq = line; eq < eol && *eq != '='; eq++) {}
        if (eq < eol) {
            char key[64];
            pkpv_trim_cp(line, eq, key, sizeof key);
            if (!str_cmp(key, "preview_ext")) pkpv_trim_cp(eq + 1, eol, pext, 64);
            else if (!str_cmp(key, "preview_exec")) pkpv_trim_cp(eq + 1, eol, pexec, 64);
        }
        line = eol + 1;
    }
}

static char pkpv_lower(char c) { return c >= 'A' && c <= 'Z' ? (char)(c + 32) : c; }

/* one of the words of list (separated by ',' or ' ', at most 63 bytes each) ends path, ASCII case-insensitively */
static bool pkpv_match_ext_ci(const char *list, const char *path)
{
    size_t plen = str_len(path);
    while (*list) {
        if (*list == ',' || *list == ' ') { list++; continue; }
        size_t n = 0;
        while (n < 63 && list[n] && list[n] != ',' && list[n] != ' ') n++;
        bool same = n <= plen;
        for (size_t i = 0; same && i < n; i++) same = pkpv_lower(path[plen - n + i]) == pkpv_lower(list[i]);
        if (same) return true;
        list += n;
    }
    return false;
}

/* `<exe> <path>`'s stdout into out_buf (at most max_len bytes): the byte count, or -1 */
static int pkpv_exec_pipe(const char *exe, const char *path, char **envp, char *out_buf, int max_len)
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
            (void)os_prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);       /* fault-checked: hardening, exec goes on either way */
            const char *argv[] = {exe, path, nullptr};
            (void)os_execve(exe, (char *const *)argv, envp);
        }
        os_exit(127);
    }
    (void)os_close(fds[1]);                                        /* fault-checked */
    int got = 0;
    bool eof = false;
    while (got < max_len) {
        int pr = os_poll_in(fds[0], PKPV_SILENCE_MS);
        if (pr == -EINTR) continue;
        if (pr <= 0) break;
        intptr_t n = os_read(fds[0], out_buf + got, (size_t)(max_len - got));
        if (n == -EINTR) continue;
        if (n <= 0) { eof = true; break; }
        got += (int)n;
    }
    (void)os_close(fds[0]);                                        /* fault-checked */
    if (!eof) (void)os_kill((int)pid, SIGKILL);                    /* fault-checked: silent, or the preview is full */
    int status;
    intptr_t w;
    while ((w = os_wait4((int)pid, &status, 0, nullptr)) == -EINTR) {}
    return os_is_err(w) ? -1 : got;
}

/* <dir>/<preview_exec> of dir's package when its preview_ext matches path: true with exe set */
static bool pkpv_match(const char *dir, const char *path, char *man, char *exe)
{
    char pext[64], pexec[64];
    size_t len;
    if (path_join(exe, dir, "manifest.ini", PATH_MAX) < 0 || fs_read_file_head(exe, man, PKPV_MANIFEST_MAX, &len) < 0) return false;
    pkpv_parse(man, (int)len, pext, pexec);
    const char *rel = pext[0] && pkpv_match_ext_ci(pext, path) ? pkm_safe_relpath(pexec) : nullptr;
    return rel && path_join(exe, dir, rel, PATH_MAX) >= 0;
}

int pkg_preview_try(char **envp, const char *filepath, char *out_buf, int max_len)
{
    char *mem = mem_alloc(3 * PATH_MAX + PKPV_DIRBUF + PKPV_MANIFEST_MAX);
    if (!mem) return -1;
    char *root = mem, *dir = mem + PATH_MAX, *exe = mem + 2 * PATH_MAX, *dents = mem + 3 * PATH_MAX, *man = dents + PKPV_DIRBUF;
    bool found = false;
    pkg_get_root(envp, root, PATH_MAX);
    intptr_t fd = root[0] ? os_openat(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0) : -ENOENT;
    for (intptr_t got; !os_is_err(fd) && !found && (got = os_dir_read((int)fd, dents, PKPV_DIRBUF)) > 0;) {
        size_t pos = 0;
        uint8_t type;
        for (const char *nm; !found && (nm = os_dir_next_ex(dents, (size_t)got, &pos, &type));)
            found = str_cmp(nm, ".") && str_cmp(nm, "..") && path_join(dir, root, nm, PATH_MAX) >= 0 && pkpv_match(dir, filepath, man, exe);
    }
    if (!os_is_err(fd)) (void)os_close((int)fd);
    int r = found ? pkpv_exec_pipe(exe, filepath, envp, out_buf, max_len) : -1;
    mem_free(mem);
    return r;
}
