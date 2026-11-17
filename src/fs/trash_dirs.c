/* src/fs/trash_dirs.c - location and naming of the XDG trash (freestanding C23; replaces the helpers of trash_undo.s):
 * the data home from the environment, the Trash/{files,info} directories and a free "<name>[.N]" slot for a new item. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

#define TU_MAX_SUFFIX 999

/* value of the first "NAME=" entry of envp (NULL when absent or empty) */
static const char *tu_find_env(const char *const *envp, const char *prefix, size_t prefix_len)
{
    if (!envp) return nullptr;
    for (; *envp; envp++) {
        if (!str_starts_with(*envp, prefix)) continue;
        const char *v = *envp + prefix_len;
        return *v ? v : nullptr;
    }
    return nullptr;
}

void tu_get_data_home(const char *const *envp, char *dst, size_t cap)
{
    const char *v = tu_find_env(envp, "XDG_DATA_HOME=", 14);
    if (v) { str_copy(dst, v, cap); return; }
    v = tu_find_env(envp, "HOME=", 5);
    if (v) {
        str_copy(dst, v, cap);
        str_cat(dst, "/.local/share", cap);
        return;
    }
    str_copy(dst, "/tmp", cap);
}

void tu_mkdir_p_base(const char *data_home)
{
    static const char *const sub[] = {"/Trash", "/Trash/files", "/Trash/info"};
    char path[PATH_MAX];
    (void)os_mkdirat(AT_FDCWD, data_home, 0700);                 /* XDG_DATA_HOME may be a directory that does not exist yet */
    for (int i = 0; i < 3; i++) {
        str_copy(path, data_home, PATH_MAX);
        str_cat(path, sub[i], PATH_MAX);
        (void)os_mkdirat(AT_FDCWD, path, 0700);
    }
}

int tu_pick_unique(const char *data_home, const char *base, char *out_files, char *out_info)
{
    FileStat st;
    for (uint32_t n = 1; n < TU_MAX_SUFFIX; n++) {
        str_copy(out_files, data_home, PATH_MAX);
        str_cat(out_files, "/Trash/files", PATH_MAX);
        (void)path_join(out_files, out_files, base, PATH_MAX);
        str_copy(out_info, data_home, PATH_MAX);
        str_cat(out_info, "/Trash/info", PATH_MAX);
        (void)path_join(out_info, out_info, base, PATH_MAX);
        if (n != 1) {
            char suffix[24] = ".";
            u64_to_dec(n, suffix + 1);
            str_cat(out_files, suffix, PATH_MAX);
            str_cat(out_info, suffix, PATH_MAX);
        }
        str_cat(out_info, ".trashinfo", PATH_MAX);
        if (os_statat(AT_FDCWD, out_files, &st, 0) < 0) return 0;
    }
    return -EEXIST;                         /* every candidate name is taken: refuse instead of overwriting */
}
