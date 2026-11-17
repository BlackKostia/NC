/* src/fs/trash_undo.c - move to the XDG trash and the 16-deep undo stack (freestanding C23; replaces trash_undo.s and
 * trash_undo_ops.s). A trashed item is written as Trash/files/<name>[.N] + Trash/info/<name>[.N].trashinfo; renames never
 * replace an existing item (fs_rename_noreplace), and across filesystems the item is copied onto a free name and the
 * original removed. Undo moves the item back the same way and drops the .trashinfo of a restored trash entry. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

typedef struct {
    int32_t kind, pad;
    char orig[PATH_MAX], cur[PATH_MAX], info[PATH_MAX];
} UndoSlot;

static UndoSlot g_undo_slots[UNDO_MAX];
static int32_t g_undo_top;

typedef struct { int rc; int src_left; } CopyMove;    /* src_left: dst is complete but removing the source failed */

/* cross-filesystem move onto a name that must still be free; a failed copy drops the partial copy and leaves the original
 * untouched (special files such as FIFOs are refused by the copy engine) */
static CopyMove tmf_copy_move(const char *src, const char *dst)
{
    FileStat st;
    if (os_statat(AT_FDCWD, dst, &st, 0) >= 0) return (CopyMove){-EEXIST, 0};
    int r = fs_copy_recursive(src, dst);
    if (r < 0) {
        (void)fs_delete_recursive(dst);
        return (CopyMove){r, 0};
    }
    return (CopyMove){fs_delete_recursive(src), 1};
}

int trash_move_file(const char *src_path, const char *const *envp, char *out_trash_path, char *out_info_path)
{
    char home[PATH_MAX];
    tu_get_data_home(envp, home, PATH_MAX);
    tu_mkdir_p_base(home);
    int r = tu_pick_unique(home, path_basename(src_path), out_trash_path, out_info_path);
    if (r < 0) return r;                                    /* no free trash name: nothing was touched */
    r = tu_write_info(out_info_path, src_path);
    if (r < 0) return r;
    intptr_t rn = fs_rename_noreplace(src_path, out_trash_path);   /* never replaces an item that is already in the trash */
    if (rn >= 0) return 0;
    if ((int)rn == -EXDEV) {
        CopyMove cm = tmf_copy_move(src_path, out_trash_path);     /* other filesystem: copy into the trash, then remove the original */
        if (cm.rc >= 0) return 0;
        if (cm.src_left) return cm.rc;                      /* trash copy is complete, original not removable: keep the info file */
        rn = cm.rc;
    }
    (void)os_unlinkat(AT_FDCWD, out_info_path, 0);
    return (int)rn;
}

void undo_push(int kind, const char *orig_path, const char *cur_path, const char *info_path)
{
    uint32_t top = (uint32_t)g_undo_top;
    if (top >= UNDO_MAX) {                                  /* full: the oldest entry falls off */
        __builtin_memmove(&g_undo_slots[0], &g_undo_slots[1], (UNDO_MAX - 1) * sizeof(UndoSlot));
        top = UNDO_MAX - 1;
    }
    UndoSlot *s = &g_undo_slots[top];
    g_undo_top = (int32_t)top + 1;
    s->kind = kind;
    str_copy(s->orig, orig_path, PATH_MAX);
    str_copy(s->cur, cur_path, PATH_MAX);
    s->info[0] = 0;
    if (info_path) str_copy(s->info, info_path, PATH_MAX);
}

int undo_pop_and_apply(void)
{
    if (g_undo_top <= 0) return 0;
    UndoSlot *s = &g_undo_slots[g_undo_top - 1];
    intptr_t r = fs_rename_noreplace(s->cur, s->orig);      /* never replaces a file that appeared at the original place meanwhile */
    if (r < 0) {
        if ((int)r == -EEXIST) return -EEXIST;              /* something is in the way: keep the entry so Ctrl+Z can be retried */
        int err = (int)r;
        if (err == -EXDEV) {
            CopyMove cm = tmf_copy_move(s->cur, s->orig);   /* other filesystem: copy back onto a free name, then remove the trash copy */
            err = cm.rc;
            if (err == -EEXIST) return -EEXIST;
        }
        if (err < 0) {
            g_undo_top--;                                   /* unrecoverable failure: the entry is dropped */
            return err;
        }
    }
    g_undo_top--;
    if (s->kind == UNDO_TRASH && s->info[0]) (void)os_unlinkat(AT_FDCWD, s->info, 0);
    return 1;
}
