/* src/tui/input_seq.c - CSI / SS3 key sequences and SGR / X10 mouse reports (freestanding C23; replaces input_seq.s).
 * Every parser starts at ESC (in_buf[in_pos]); an incomplete or oversized sequence degrades to a bare ESC key. */
#include "duop_tui.h"

typedef struct { uint8_t ch; int32_t key; } KeyRow;

static const KeyRow ss3_keys[] = {
    {'P', KEY_F1}, {'Q', KEY_F2}, {'R', KEY_F3}, {'S', KEY_F4}, {'H', KEY_HOME}, {'F', KEY_END},
    {'A', KEY_UP}, {'B', KEY_DOWN}, {'C', KEY_RIGHT}, {'D', KEY_LEFT},
};
static const KeyRow csi_keys[] = {
    {'A', KEY_UP}, {'B', KEY_DOWN}, {'C', KEY_RIGHT}, {'D', KEY_LEFT}, {'H', KEY_HOME}, {'F', KEY_END}, {'Z', KEY_BTAB},
    {'P', KEY_F1}, {'Q', KEY_F2}, {'R', KEY_F3}, {'S', KEY_F4},
};
static const struct { uint8_t num; int32_t key; } csi_tilde[] = {
    {1, KEY_HOME}, {7, KEY_HOME}, {2, KEY_INSERT}, {3, KEY_DELETE}, {4, KEY_END}, {8, KEY_END}, {5, KEY_PGUP}, {6, KEY_PGDN},
    {11, KEY_F1}, {12, KEY_F2}, {13, KEY_F3}, {14, KEY_F4}, {15, KEY_F5}, {17, KEY_F6}, {18, KEY_F7}, {19, KEY_F8},
    {20, KEY_F9}, {21, KEY_F10}, {23, KEY_F11}, {24, KEY_F12},
};

static int bare_esc(Event *evt)
{
    in_pos++;
    evt->type = EVT_KEY;
    evt->key = KEY_ESC;
    return 1;
}

/* bytes of the sequence at in_pos that are buffered; waits up to 15 ms for `need` of them */
static bool have_bytes(uint32_t need)
{
    if (in_len - in_pos >= need) return true;
    wait_and_read(15);
    return in_len - in_pos >= need;
}

int input_parse_ss3(Event *evt)                 /* ESC O x */
{
    if (!have_bytes(3)) return bare_esc(evt);
    uint32_t c = in_buf[in_pos + 2];
    in_pos += 3;
    evt->type = EVT_KEY;
    for (size_t i = 0; i < sizeof ss3_keys / sizeof ss3_keys[0]; i++)
        if (ss3_keys[i].ch == c) { evt->key = ss3_keys[i].key; return 1; }
    return 0;
}

/* ESC [ params final: params = [params, fin) is "n" or "n;modifier" */
static int csi_dispatch(Event *evt, const uint8_t *params, const uint8_t *fin, uint32_t final_ch)
{
    const uint8_t *p = params;
    uint32_t first = 0, mod = 0;
    if (p < fin) {
        first = parse_uint_adv(&p);
        if (p < fin && *p == ';' && ++p < fin) mod = parse_uint_adv(&p);
    }
    int32_t mods = 0;
    if ((int32_t)mod > 1) {                     /* xterm modifier: 1 + bitmask */
        uint32_t m = mod - 1;
        mods = (m & 1 ? MOD_SHIFT : 0) | (m & 2 ? MOD_ALT : 0) | (m & 4 ? MOD_CTRL : 0);
    }
    evt->mods = mods;
    evt->type = EVT_KEY;
    if (final_ch == '~') {
        for (size_t i = 0; i < sizeof csi_tilde / sizeof csi_tilde[0]; i++)
            if (csi_tilde[i].num == first) { evt->key = csi_tilde[i].key; return 1; }
    } else {
        for (size_t i = 0; i < sizeof csi_keys / sizeof csi_keys[0]; i++)
            if (csi_keys[i].ch == final_ch) { evt->key = csi_keys[i].key; return 1; }
    }
    return 0;
}

/* SGR 1006 report: button bits 4/8/16 = Shift/Alt/Ctrl, 32 = motion, 64 = wheel; 'm' final = release */
static int sgr_finish(Event *evt, uint32_t btn, int32_t col, int32_t row, uint32_t final_ch)
{
    evt->type = EVT_MOUSE;
    int32_t x = (int32_t)((uint32_t)col - 1), y = (int32_t)((uint32_t)row - 1);   /* 1-based on the wire, clamped at 0 */
    evt->mouse_x = x < 0 ? 0 : x;
    evt->mouse_y = y < 0 ? 0 : y;
    evt->mods = (btn & 4 ? MOD_SHIFT : 0) | (btn & 8 ? MOD_ALT : 0) | (btn & 16 ? MOD_CTRL : 0);
    if (btn & 64) {
        evt->mouse_kind = MACT_WHEEL;
        evt->mouse_btn = btn & 1 ? MOUSE_WHEEL_DOWN : MOUSE_WHEEL_UP;
        return 1;
    }
    evt->mouse_btn = (int32_t)(btn & 3);
    if (btn & 32) evt->mouse_kind = evt->mouse_btn == MOUSE_NONE ? MACT_MOVE : MACT_DRAG;
    else evt->mouse_kind = final_ch == 'm' ? MACT_RELEASE : MACT_PRESS;
    return 1;
}

/* Scans from ESC for `stop(byte)`; returns the buffer index of the stopping byte, or -1 when the sequence is
 * unterminated/oversized (then the caller emits a bare ESC). Waits 15 ms per missing chunk. */
static long find_final(uint32_t skip, bool mouse)
{
    for (uint32_t i = skip;;) {
        uint32_t idx = in_pos + i;
        if (idx < in_len) {
            uint32_t b = in_buf[idx];
            if (mouse ? (b == 'M' || b == 'm') : (b >= 0x40 && b <= 0x7E)) return idx;
            if (++i >= 510) return -1;
            continue;
        }
        if (in_len - in_pos >= IN_BUF_SIZE || wait_and_read(15) <= 0) return -1;
    }
}

static int parse_sgr_mouse(Event *evt)          /* ESC [ < b ; x ; y M|m */
{
    long at = find_final(3, true);
    if (at < 0) return bare_esc(evt);
    const uint8_t *p = in_buf + in_pos + 3, *fin = in_buf + at;
    uint32_t ch = in_buf[at];
    in_pos = (uint32_t)at + 1;
    if (p >= fin) return 0;
    uint32_t b = parse_uint_adv(&p);
    if (p >= fin || *p++ != ';') return 0;
    uint32_t col = parse_uint_adv(&p);
    if (p >= fin || *p++ != ';') return 0;
    uint32_t row = parse_uint_adv(&p);
    return sgr_finish(evt, b, (int32_t)col, (int32_t)row, ch);
}

static int parse_x10_mouse(Event *evt)          /* ESC [ M b x y, each +32 */
{
    if (!have_bytes(6)) return bare_esc(evt);
    uint32_t b = (uint32_t)in_buf[in_pos + 3] - 32, x = in_buf[in_pos + 4], y = in_buf[in_pos + 5];
    in_pos += 6;
    evt->type = EVT_MOUSE;
    evt->mouse_x = x > 33 ? (int32_t)x - 33 : 0;
    evt->mouse_y = y > 33 ? (int32_t)y - 33 : 0;
    if (b & 64) {
        evt->mouse_kind = MACT_WHEEL;
        evt->mouse_btn = b & 1 ? MOUSE_WHEEL_DOWN : MOUSE_WHEEL_UP;
        return 1;
    }
    evt->mouse_btn = (int32_t)(b & 3);
    evt->mouse_kind = evt->mouse_btn == MOUSE_NONE ? MACT_RELEASE : MACT_PRESS;
    return 1;
}

int input_parse_csi(Event *evt)                 /* ESC [ ... */
{
    if (!have_bytes(3)) return bare_esc(evt);
    uint32_t c = in_buf[in_pos + 2];
    if (c == '<') return parse_sgr_mouse(evt);
    if (c == 'M') return parse_x10_mouse(evt);
    long at = find_final(2, false);
    if (at < 0) return bare_esc(evt);
    const uint8_t *params = in_buf + in_pos + 2, *fin = in_buf + at;
    uint32_t final_ch = in_buf[at];
    in_pos = (uint32_t)at + 1;
    return csi_dispatch(evt, params, fin, final_ch);
}
