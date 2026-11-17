/* src/tui/kbd_layout.c - keyboard layouts as data (freestanding C23; replaces kbd_layout.s).
 * Every "*.layout" file on the data path (data_dirs.c: $DUOP_LAYOUTS, ~/.config/duop/layouts, layouts/ beside the
 * binary, share/duop/layouts) is loaded at startup into the kbd_map.c table, so hotkeys work in any layout and new
 * layouts need no rebuild. */
#include "duop_tui.h"

static void kl_load_file(const char *path, const char *name)
{
    (void)name;
    char *buf = mem_alloc(KBD_FILE_MAX);
    if (!buf) return;
    if (data_read_file(path, buf, KBD_FILE_MAX) >= 0) kbd_layout_parse(buf);
    mem_free(buf);
}

static const DataSpec kbd_spec = { "DUOP_LAYOUTS=", "layouts", ".layout", kl_load_file };

void kbd_layout_load(char **envp)
{
    kbd_map_reset();
    data_dirs_scan(envp, &kbd_spec);
}
