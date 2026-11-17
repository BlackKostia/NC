/* src/tui/data_dirs.c - runtime data directories (freestanding C23; replaces data_dirs.s).
 *
 * Finds every "*<ext>" file of one DataSpec kind (keyboard layouts, interface language packs, ...) so such data is
 * added without rebuilding. Search path:
 *   $<env>                       ':'-separated directories; when set, replaces everything below
 *   $XDG_CONFIG_HOME/duop/<sub>  or  ~/.config/duop/<sub>
 *   <binary dir>/<sub>, <binary dir>/../share/duop/<sub>   (AT_EXECFN, one symlink level)
 *   /usr/local/share/duop/<sub>, /usr/share/duop/<sub>
 * Directories are visited in this order, so loaders can let the first file of a kind win.
 *
 * The path buffers live in .bss (a scan is single-threaded and never re-entered by a loader), which keeps every
 * stack frame small for the 4 KiB dirent batches and PATH_MAX paths. */
#include "duop_config.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"

#define DD_DENTS 4096

static const DataSpec *g_ds_spec;                 /* DataSpec of the scan in progress */
static char g_dd_base[PATH_MAX];                  /* directory being combined with <mid>/<sub> */
static char g_dd_dir[PATH_MAX];                   /* base/<mid>/<sub>, or one segment of $<env> */
static char g_dd_file[PATH_MAX];                  /* dir/<file name> handed to the loader; also the readlink buffer */
static char g_dd_dents[DD_DENTS] __attribute__((aligned(8)));

/* "<something><ext>" and not hidden */
static bool ds_name_match(const char *name)
{
    if (name[0] == '.') return false;
    size_t n = str_len(name), e = str_len(g_ds_spec->ext);
    return n > e && str_cmp(name + (n - e), g_ds_spec->ext) == 0;
}

/* spec->load for each matching file of one directory */
static void ds_scan_dir(const char *dir)
{
    intptr_t fd = os_openat(AT_FDCWD, dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (os_is_err(fd)) return;
    for (;;) {
        intptr_t n = os_dir_read((int)fd, g_dd_dents, DD_DENTS);
        if (n <= 0) break;
        size_t pos = 0;
        const char *name;
        while ((name = os_dir_next(g_dd_dents, (size_t)n, &pos)) != nullptr) {
            if (!ds_name_match(name)) continue;
            if (path_join(g_dd_file, dir, name, PATH_MAX) < 0) continue;
            g_ds_spec->load(g_dd_file, name);
        }
    }
    os_close((int)fd);
}

/* scan <g_dd_base>/<mid>/<spec sub> */
static void ds_scan_sub(const char *mid)
{
    if (path_join(g_dd_dir, g_dd_base, mid, PATH_MAX) < 0) return;
    if (path_join(g_dd_dir, g_dd_dir, g_ds_spec->sub, PATH_MAX) < 0) return;
    ds_scan_dir(g_dd_dir);
}

/* every directory of a ':'-separated list (an over-long entry is truncated, then simply not found) */
static void ds_scan_list(const char *list)
{
    for (;;) {
        size_t n = 0;
        while (*list && *list != ':') {
            if (n < PATH_MAX - 1) g_dd_base[n++] = *list;
            list++;
        }
        g_dd_base[n] = 0;
        if (n) ds_scan_dir(g_dd_base);
        if (!*list) return;
        list++;
    }
}

/* $XDG_CONFIG_HOME or $HOME into out; returns the part to append ("duop" / ".config/duop"), or nullptr when neither is set */
static const char *ds_user_base(char **envp, char *out)
{
    const char *v = cfg_getenv(envp, "XDG_CONFIG_HOME=");
    const char *mid = "duop";
    if (!v || !*v) {
        v = cfg_getenv(envp, "HOME=");
        mid = ".config/duop";
        if (!v || !*v) return nullptr;
    }
    str_copy(out, v, PATH_MAX);
    return mid;
}

/* AT_EXECFN from the auxiliary vector (it follows the envp array), or nullptr */
static const char *ds_execfn(char **envp)
{
    if (!envp) return nullptr;
    const uintptr_t *p = (const uintptr_t *)envp;
    while (*p++) {}
    for (; p[0]; p += 2)
        if (p[0] == OS_AT_EXECFN) return (const char *)p[1];
    return nullptr;
}

/* out = directory of the real binary (one symlink level: ~/.local/bin/duop -> ~/src/duop/duop resolves to ~/src/duop) */
static void ds_exe_dir(const char *path, char *out)
{
    const char *real = path;
    intptr_t n = os_readlinkat(AT_FDCWD, path, g_dd_file, PATH_MAX - 1);
    if (n > 0) {
        g_dd_file[n] = 0;
        real = g_dd_file;
        if (g_dd_file[0] != '/') {                    /* relative target: <link dir>/<target> */
            path_dirname(path, out, PATH_MAX);
            path_join(out, out, g_dd_file, PATH_MAX);
            real = out;
        }
    }
    path_dirname(real, out, PATH_MAX);
}

void data_dirs_scan(char **envp, const DataSpec *spec)
{
    g_ds_spec = spec;
    const char *list = cfg_getenv(envp, spec->env);
    if (list && *list) { ds_scan_list(list); return; }
    const char *mid = ds_user_base(envp, g_dd_base);
    if (mid) ds_scan_sub(mid);
    const char *exe = ds_execfn(envp);
    if (exe) {
        ds_exe_dir(exe, g_dd_base);
        ds_scan_sub("");                              /* <binary dir>/<sub> */
        ds_scan_sub("../share/duop");
    }
    str_copy(g_dd_base, "/usr/local/share/duop", PATH_MAX);
    ds_scan_sub("");
    str_copy(g_dd_base, "/usr/share/duop", PATH_MAX);
    ds_scan_sub("");
}

intptr_t data_read_file(const char *path, char *buf, size_t cap)
{
    if (!cap) return -1;                              /* no room even for the terminator */
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_CLOEXEC, 0);
    if (os_is_err(fd)) return -1;
    size_t total = 0;
    while (total < cap - 1) {
        intptr_t n = sys_read_retry((int)fd, buf + total, cap - 1 - total);
        if (n <= 0) break;
        total += (size_t)n;
    }
    buf[total] = 0;
    os_close((int)fd);
    return (intptr_t)total;
}
