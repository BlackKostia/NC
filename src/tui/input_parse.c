/* src/tui/input_parse.c - keyboard decoder front end (freestanding C23; replaces input_parse.s).
 *
 * input_poll_event() turns the next bytes of in_buf into one Event: SIGWINCH resize, control keys, UTF-8 characters
 * (waiting briefly for a split multi-byte sequence), Alt+key, and hands ESC [ / ESC O to input_seq.c. A lone ESC is
 * told from a sequence start by waiting 25 ms. */
#include "duop_sys.h"
#include "duop_tui.h"

typedef struct { uint64_t cp, len; } Utf8Dec;
Utf8Dec utf8_decode(const char *s);

static int key_event(Event *evt, int32_t key, int32_t mods)
{
    evt->type = EVT_KEY;
    evt->mods = mods;
    evt->key = key;
    return 1;
}

static int resize_event(Event *evt)
{
    g_sigwinch = 0;
    evt->type = EVT_RESIZE;
    return 1;
}

/* decode the UTF-8 character at in_buf[at]: {code point, bytes}; a NUL-less tail or malformed byte falls back to the raw byte */
[[gnu::always_inline]] static inline Utf8Dec decode_at(uint32_t at)
{
    if (in_len > IN_BUF_SIZE - 1) return (Utf8Dec){in_buf[at], 1};
    in_buf[in_len] = 0;                                    /* temporary terminator in the slack byte */
    Utf8Dec d = utf8_decode((const char *)in_buf + at);
    return d.len ? d : (Utf8Dec){in_buf[at], 1};
}

static int plain_key(Event *evt, uint32_t c)
{
    if (c == 0x09) { in_pos++; return key_event(evt, KEY_TAB, 0); }
    if (c == 0x0D || c == 0x0A) { in_pos++; return key_event(evt, KEY_ENTER, 0); }
    if (c == 0x7F || c == 0x08) { in_pos++; return key_event(evt, KEY_BACKSPACE, 0); }
    if (c <= 0x1A) { in_pos++; return key_event(evt, (int32_t)c + 'a' - 1, MOD_CTRL); }
    if (c >= 0xC0 && in_len - in_pos < 4) wait_and_read(10);   /* the rest of a multi-byte character */
    Utf8Dec d = decode_at(in_pos);
    in_pos += (uint32_t)d.len;
    return key_event(evt, (int32_t)d.cp, 0);
}

/* ESC followed by a character: Alt+key (ASCII byte or a UTF-8 letter) */
static int alt_key(Event *evt, uint32_t c2)
{
    Utf8Dec d = {c2, 1};
    if (c2 >= 0xC0) {
        if (in_len - in_pos < 4) wait_and_read(10);
        d = decode_at(in_pos + 1);
    }
    in_pos += (uint32_t)d.len + 1;                         /* the ESC and the character */
    return key_event(evt, (int32_t)d.cp, MOD_ALT);
}

int input_poll_event(Event *evt, int timeout_ms)
{
    mem_zero(evt, sizeof *evt);
    if (g_sigwinch) return resize_event(evt);
    if (in_pos >= in_len) {
        int r = wait_and_read_fd(timeout_ms, 1);
        if (r == -1) return g_sigwinch ? resize_event(evt) : 0;
        if (r == -2) return -2;
        if (r <= 0) return 0;
    }
    uint32_t c = in_buf[in_pos];
    if (c != 0x1B) return plain_key(evt, c);
    if (in_len - in_pos <= 1) {
        wait_and_read(25);                                 /* a lone ESC, or the start of a sequence? */
        if (in_len - in_pos <= 1) { in_pos++; return key_event(evt, KEY_ESC, 0); }
    }
    uint32_t c2 = in_buf[in_pos + 1];
    if (c2 == '[') return input_parse_csi(evt);
    if (c2 == 'O') return input_parse_ss3(evt);
    if (c2 == 0x1B) { in_pos++; return key_event(evt, KEY_ESC, 0); }
    return alt_key(evt, c2);
}
