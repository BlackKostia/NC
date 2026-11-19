/* src/ui/dialogs_input_keys.c - InputDialog line-editing key handler with UTF-8 cursor movement
 * (freestanding C23; replaces dialogs_input_keys.s, kept as tests/harness/dialogs_input_keys_reference.s). */
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"

static uint32_t idk_prev_char(const InputDialog *dlg, uint32_t c)
{
    do {
        c--;
    } while (c > 0 && (dlg->buf[c] & 0xC0u) == 0x80u);
    return c;
}

static uint32_t idk_next_char(const InputDialog *dlg, uint32_t c)
{
    do {
        c++;
    } while (c < dlg->len && (dlg->buf[c] & 0xC0u) == 0x80u);
    return c;
}

static int idk_backspace(InputDialog *dlg)
{
    if (dlg->cursor == 0) return 0;
    uint32_t old = dlg->cursor;
    uint32_t c = idk_prev_char(dlg, old);
    uint32_t removed = old - c;
    mem_move(dlg->buf + c, dlg->buf + old, (size_t)(dlg->len - old + 1));
    dlg->len -= removed;
    dlg->cursor = c;
    return 1;
}

static int idk_delete(InputDialog *dlg)
{
    if (dlg->cursor >= dlg->len) return 0;
    uint32_t c = dlg->cursor;
    uint32_t end = idk_next_char(dlg, c);
    uint32_t removed = end - c;
    mem_move(dlg->buf + c, dlg->buf + end, (size_t)(dlg->len - end + 1));
    dlg->len -= removed;
    return 1;
}

static int idk_insert(InputDialog *dlg, uint32_t key)
{
    if (key < 0x20u || key > 0x10FFFFu) return 0;
    char enc[8];
    int n = utf8_encode(key, enc);
    if (dlg->len + (uint32_t)n >= INPUT_MAX - 1) return 0;
    mem_move(dlg->buf + dlg->cursor + n, dlg->buf + dlg->cursor,
             (size_t)(dlg->len - dlg->cursor + 1));
    mem_copy(dlg->buf + dlg->cursor, enc, (size_t)n);
    dlg->len += (uint32_t)n;
    dlg->cursor += (uint32_t)n;
    return 1;
}

static int idk_nav(InputDialog *dlg, uint32_t key)
{
    switch (key) {
    case KEY_TAB:   dlg->base.focus_btn ^= 1; return 1;
    case KEY_HOME:  dlg->cursor = 0; return 1;
    case KEY_END:   dlg->cursor = dlg->len; return 1;
    case KEY_LEFT:
        if (dlg->cursor == 0) return 0;
        dlg->cursor = idk_prev_char(dlg, dlg->cursor);
        return 1;
    case KEY_RIGHT:
        if (dlg->cursor >= dlg->len) return 0;
        dlg->cursor = idk_next_char(dlg, dlg->cursor);
        return 1;
    case KEY_BACKSPACE: return idk_backspace(dlg);
    case KEY_DELETE:    return idk_delete(dlg);
    default:            return idk_insert(dlg, key);
    }
}

int InputDialog_on_key(Widget *self, void *event)
{
    InputDialog *dlg = (InputDialog *)self;
    const Event *e = (const Event *)event;
    uint32_t key = (uint32_t)e->key;
    uint32_t mods = (uint32_t)e->mods;
    int dirty = 0;

    if (mods & MOD_CTRL) {
        if (key == 'u') {
            dlg->len = 0;
            dlg->cursor = 0;
            dlg->buf[0] = 0;
            dirty = 1;
        }
    } else if (key == KEY_ESC) {
        DIALOG_CALL(dlg, on_cancel);
    } else if (key == KEY_ENTER) {
        if (dlg->base.focus_btn == 0) DIALOG_CALL(dlg, on_confirm);
        else DIALOG_CALL(dlg, on_cancel);
    } else {
        dirty = idk_nav(dlg, key);
    }

    if (dirty) {
        App *app = (App *)(uintptr_t)dlg->base.app;
        app->need_redraw = 1;
    }
    return 1;
}
