/* src/fs/dir_diff.c - Dir Diff helper (freestanding C23; replaces dir_diff.s): marks entries of the active DirModel
 * that are missing in, or differ in size from, the opposite DirModel (".." is ignored, directories only need to exist). */
#include "duop_fs.h"
#include "duop_string.h"

int dir_diff_mark(DirModel *active, DirModel *other)
{
    int diffs = 0;
    if (!active || !other) return 0;
    for (uint64_t i = 0; i < active->raw_count; i++) {
        FileEntry *e = &active->entries[i];
        const char *name = active->name_pool + e->name_off;
        e->flags &= ~(uint32_t)FE_SELECTED;
        if (name[0] == '.' && name[1] == '.' && !name[2]) continue;                  /* skip ".." */
        bool differs = true;
        for (uint64_t j = 0; j < other->raw_count; j++) {
            const FileEntry *o = &other->entries[j];
            if (str_cmp(name, other->name_pool + o->name_off)) continue;
            uint32_t dir = e->flags & FE_IS_DIR;
            differs = dir != (o->flags & FE_IS_DIR) || (!dir && e->size != o->size);   /* both directories: equal */
            break;
        }
        if (differs) { e->flags |= FE_SELECTED; diffs++; }
    }
    return diffs;
}
