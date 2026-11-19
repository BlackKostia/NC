/* src/ui/term_keys.c - embedded PTY key encoder: Event -> xterm/VT byte sequence (freestanding C23; replaces
 * src/ui/term_keys.s, kept as tests/harness/term_keys_reference.s). */
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"

typedef struct { uint8_t len; char bytes[4]; } TkSeq;

static const TkSeq tk_special[KEY_ESC - KEY_UP + 1] = {
    {3, "\x1b[A"},   /* KEY_UP */
    {3, "\x1b[B"},   /* KEY_DOWN */
    {3, "\x1b[D"},   /* KEY_LEFT */
    {3, "\x1b[C"},   /* KEY_RIGHT */
    {3, "\x1b[H"},   /* KEY_HOME */
    {3, "\x1b[F"},   /* KEY_END */
    {4, "\x1b[5~"},  /* KEY_PGUP */
    {4, "\x1b[6~"},  /* KEY_PGDN */
    {4, "\x1b[2~"},  /* KEY_INSERT */
    {4, "\x1b[3~"},  /* KEY_DELETE */
    {1, "\x7f"},     /* KEY_BACKSPACE */
    {1, "\t"},       /* KEY_TAB */
    {3, "\x1b[Z"},   /* KEY_BTAB */
    {1, "\r"},       /* KEY_ENTER */
    {1, "\x1b"},     /* KEY_ESC */
};

int term_key_encode(const void *evt, char *out)
{
    const Event *e = evt;
    uint32_t key = (uint32_t)e->key;
    uint32_t mods = (uint32_t)e->mods;
    if (key >= KEY_UP) {
        if (key > KEY_ESC) return -1;
        const TkSeq *s = &tk_special[key - KEY_UP];
        __builtin_memcpy(out, s->bytes, 4);
        return s->len;
    }
    if (key >= 0x110000u) return 0;
    int pfx = 0;
    if (mods & MOD_ALT) {
        out[0] = 0x1B;
        out++;
        pfx = 1;
    }
    if ((mods & MOD_CTRL) && key >= 0x20u && key <= 0x7Eu) key &= 0x1Fu;
    return utf8_encode(key, out) + pfx;
}
