/* src/tui/i18n_keys.c - pack key -> LangStrings slot (freestanding C23; replaces i18n_keys.s).
 *
 * The names of the slots, in slot order, are the NUL-separated `i18n_key_blob` that tools/gen_i18n.py writes into
 * build/i18n_en.c from include/types.inc (array fields numbered from 1: f_labels.1 ... help_lines.22), so a key is
 * its slot number times the slot size and the table cannot drift from the English text next to it. */
#include "duop_string.h"
#include "duop_tui.h"

/* byte offset of the LangStrings slot named `key`, or -1 */
int i18n_key_offset(const char *key)
{
    const char *name = i18n_key_blob;
    for (size_t slot = 0; slot < LANG_SLOTS; slot++) {
        if (!str_cmp(name, key)) return (int)(slot * sizeof(char *));
        name += str_len(name) + 1;
    }
    return -1;
}
